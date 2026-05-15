<#
.SYNOPSIS
    Azure VM Inventory Script (hardened) — works in Cloud Shell and locally.

.DESCRIPTION
    Every Azure call is independently fault-tolerant. A single failure on one
    property (e.g. NIC, disk, backup) will NOT skip the entire VM — partial
    rows are still written.

    Input options:
      -VMListFile <path>        : text file of VM names (one per line)
      -SubscriptionFile <path>  : text file of subscription IDs/names
      -VMName <list>            : inline VM names
      -SubscriptionId <list>    : inline subscription IDs/names
      (none of the above)       : process all VMs in all accessible subs

    Output: 3 CSVs in a timestamped folder
      VMs.csv, Disks.csv, SQL.csv  (+ NotFound.txt and Errors.log if any)

.EXAMPLES
    .\Get-AzureVMInventory.ps1 -VMListFile .\vms.txt
    .\Get-AzureVMInventory.ps1 -VMListFile .\vms.txt -SkipRunCommand
    .\Get-AzureVMInventory.ps1 -SubscriptionFile .\subs.txt
#>

[CmdletBinding()]
param(
    [string]$VMListFile,
    [string]$SubscriptionFile,
    [string[]]$VMName,
    [string[]]$SubscriptionId,
    [string]$OutputPath = (Join-Path $PWD "AzureVMInventory_$(Get-Date -Format 'yyyyMMdd_HHmmss')"),
    [switch]$SkipRunCommand,
    [int]$RunCommandTimeoutSec = 180
)

$ErrorActionPreference = 'Continue'
if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }

$errorLog = Join-Path $OutputPath 'Errors.log'
function Log-Err($msg) {
    Add-Content -Path $errorLog -Value "[$(Get-Date -Format 'HH:mm:ss')] $msg"
    Write-Warning $msg
}

Write-Host "==> Output directory: $OutputPath" -ForegroundColor Cyan

# ---------- Helper: safe property accessor ----------
function Get-Prop {
    param($Object, [string]$Path, $Default = '')
    if ($null -eq $Object) { return $Default }
    $parts = $Path -split '\.'
    $cur = $Object
    foreach ($p in $parts) {
        if ($null -eq $cur) { return $Default }
        try { $cur = $cur.$p } catch { return $Default }
    }
    if ($null -eq $cur) { return $Default }
    return $cur
}

# ---------- Helper: read a list file ----------
function Read-ListFile {
    param([string]$Path)
    if (-not (Test-Path $Path)) { throw "File not found: $Path" }
    Get-Content -Path $Path |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and -not $_.StartsWith('#') } |
        ForEach-Object { ($_ -split '[#;]')[0].Trim() } |
        Where-Object { $_ }
}

# ---------- Resolve inputs ----------
$targetVMs  = @()
$targetSubs = @()

if ($VMListFile)       { $targetVMs  += Read-ListFile -Path $VMListFile }
if ($VMName)           { $targetVMs  += $VMName }
if ($SubscriptionFile) { $targetSubs += Read-ListFile -Path $SubscriptionFile }
if ($SubscriptionId)   { $targetSubs += $SubscriptionId }

$targetVMs  = @($targetVMs  | Select-Object -Unique)
$targetSubs = @($targetSubs | Select-Object -Unique)

if ($targetVMs.Count)  { Write-Host "==> Filtering to $($targetVMs.Count) VM name(s)" -ForegroundColor Cyan }
if ($targetSubs.Count) { Write-Host "==> Filtering to $($targetSubs.Count) subscription(s)" -ForegroundColor Cyan }
if (-not $targetVMs.Count -and -not $targetSubs.Count) {
    Write-Host "==> No filters; scanning ALL accessible subscriptions and VMs" -ForegroundColor Yellow
}

# ---------- Ensure logged in ----------
$ctx = Get-AzContext -ErrorAction SilentlyContinue
if (-not $ctx) {
    Write-Host "Not logged in. Running Connect-AzAccount..." -ForegroundColor Yellow
    try { Connect-AzAccount -ErrorAction Stop | Out-Null }
    catch { throw "Login failed: $($_.Exception.Message)" }
}

# ---------- Pick subscriptions ----------
$subs = @()
try {
    $allSubs = Get-AzSubscription -ErrorAction Stop
} catch {
    throw "Could not enumerate subscriptions: $($_.Exception.Message)"
}

if ($targetSubs.Count) {
    foreach ($s in $targetSubs) {
        $match = $allSubs | Where-Object { $_.Id -eq $s -or $_.Name -eq $s }
        if ($match) { $subs += $match }
        else { Log-Err "Subscription not found / no access: $s" }
    }
} else {
    $subs = $allSubs | Where-Object { $_.State -eq 'Enabled' }
}

$subs = @($subs | Sort-Object Id -Unique)
Write-Host "==> Will scan $($subs.Count) subscription(s)`n" -ForegroundColor Cyan
if ($subs.Count -eq 0) { throw "No subscriptions to scan. Exiting." }

# ---------- Collections ----------
$vmInventory   = New-Object System.Collections.Generic.List[object]
$diskInventory = New-Object System.Collections.Generic.List[object]
$sqlInventory  = New-Object System.Collections.Generic.List[object]
$notFound      = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($n in $targetVMs) { [void]$notFound.Add($n) }

# Per-location SKU cache (replaces broken Get-AzVMSize)
$skuCache = @{}

function Get-SizeInfo {
    param([string]$Location, [string]$SkuName)
    if (-not $skuCache.ContainsKey($Location)) {
        $skuCache[$Location] = @{}
        try {
            $skus = Get-AzComputeResourceSku -Location $Location -ErrorAction Stop |
                    Where-Object { $_.ResourceType -eq 'virtualMachines' }
            foreach ($sku in $skus) {
                $cores = ($sku.Capabilities | Where-Object Name -eq 'vCPUs').Value
                $memGB = ($sku.Capabilities | Where-Object Name -eq 'MemoryGB').Value
                $maxDD = ($sku.Capabilities | Where-Object Name -eq 'MaxDataDiskCount').Value
                $skuCache[$Location][$sku.Name] = [PSCustomObject]@{
                    Cores = if ($cores) {[int]$cores} else {$null}
                    MemGB = if ($memGB) {[double]$memGB} else {$null}
                    MaxDD = if ($maxDD) {[int]$maxDD} else {$null}
                }
            }
        } catch {
            Log-Err "Could not fetch SKU catalog for ${Location}: $($_.Exception.Message)"
        }
    }
    if ($skuCache[$Location].ContainsKey($SkuName)) { return $skuCache[$Location][$SkuName] }
    return [PSCustomObject]@{ Cores = $null; MemGB = $null; MaxDD = $null }
}

# ---------- In-guest scripts ----------
$winScript = @'
$ErrorActionPreference = 'SilentlyContinue'
$out = [ordered]@{}
$cs = Get-CimInstance Win32_ComputerSystem
$os = Get-CimInstance Win32_OperatingSystem
$out.Hostname     = $env:COMPUTERNAME
$out.FQDN         = "$($cs.DNSHostName).$($cs.Domain)"
$out.DomainJoined = $cs.PartOfDomain
$out.Domain       = $cs.Domain
$out.OSName       = $os.Caption
$out.OSVersion    = $os.Version
$out.OSBuild      = $os.BuildNumber
$out.OSArch       = $os.OSArchitecture
$out.LastBootTime = $os.LastBootUpTime
$out.TimeZone     = (Get-TimeZone).Id
$out.InstallDate  = $os.InstallDate
$drives = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" | ForEach-Object {
    "{0}|{1}|{2:N1}GB|{3:N1}GB|{4:N1}%" -f $_.DeviceID, $_.FileSystem,
        ($_.Size/1GB), ($_.FreeSpace/1GB), (($_.Size - $_.FreeSpace)/$_.Size*100)
}
$out.Drives = ($drives -join '; ')
$pending = $false
if (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending' -EA SilentlyContinue) {$pending=$true}
if (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired' -EA SilentlyContinue) {$pending=$true}
$out.PendingReboot = $pending
$out.LastHotfix = (Get-HotFix | Sort-Object InstalledOn -Descending | Select-Object -First 1 -ExpandProperty InstalledOn)
$def = Get-MpComputerStatus
$out.DefenderEnabled = $def.AntivirusEnabled
$out.DefenderSigDate = $def.AntivirusSignatureLastUpdated
$out.LocalAdmins = (Get-LocalGroupMember -Group 'Administrators' -EA SilentlyContinue | Select-Object -Expand Name) -join '; '
$sqlData = @()
$sqlInstances = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL' -EA SilentlyContinue
if ($sqlInstances) {
    foreach ($prop in $sqlInstances.PSObject.Properties) {
        if ($prop.Name -in 'PSPath','PSParentPath','PSChildName','PSDrive','PSProvider') { continue }
        $instName = $prop.Name
        $instId   = $prop.Value
        $setup    = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$instId\Setup" -EA SilentlyContinue
        $svcName  = if ($instName -eq 'MSSQLSERVER') {'MSSQLSERVER'} else {"MSSQL`$$instName"}
        $svc      = Get-Service -Name $svcName -EA SilentlyContinue
        $dbs = ''
        try {
            $serverName = if ($instName -eq 'MSSQLSERVER') {$env:COMPUTERNAME} else {"$env:COMPUTERNAME\$instName"}
            $conn = New-Object System.Data.SqlClient.SqlConnection "Server=$serverName;Integrated Security=True;Connection Timeout=10"
            $conn.Open()
            $cmd = $conn.CreateCommand()
            $cmd.CommandText = "SELECT name, recovery_model_desc, state_desc FROM sys.databases"
            $rdr = $cmd.ExecuteReader()
            $list = @()
            while ($rdr.Read()) { $list += "$($rdr['name'])($($rdr['recovery_model_desc']))" }
            $dbs = $list -join ','
            $conn.Close()
        } catch { $dbs = "ERR:$($_.Exception.Message)" }
        $sqlData += [PSCustomObject]@{
            Instance     = $instName
            Edition      = $setup.Edition
            Version      = $setup.Version
            PatchLevel   = $setup.PatchLevel
            ServiceState = $svc.Status
            StartMode    = $svc.StartType
            Databases    = $dbs
        }
    }
}
$out.SQL = ($sqlData | ConvertTo-Json -Compress -Depth 3)
$out | ConvertTo-Json -Compress -Depth 4
'@

$linScript = @'
echo "---HOSTNAME---"; hostname -f 2>/dev/null || hostname
echo "---OS---"; cat /etc/os-release 2>/dev/null | grep -E "^(NAME|VERSION|PRETTY_NAME)="
echo "---KERNEL---"; uname -r
echo "---UPTIME---"; uptime -s 2>/dev/null
echo "---TZ---"; timedatectl 2>/dev/null | grep "Time zone"
echo "---DRIVES---"; df -hPT --output=source,fstype,size,used,avail,pcent,target | grep -vE "tmpfs|udev|overlay|squashfs"
echo "---SQL---"
if systemctl is-active mssql-server >/dev/null 2>&1; then
  /opt/mssql/bin/sqlservr -v 2>/dev/null || echo "mssql-server: active"
  systemctl status mssql-server --no-pager | grep -E "Active|Loaded"
else
  echo "no_mssql"
fi
echo "---PENDINGREBOOT---"
if [ -f /var/run/reboot-required ]; then echo "YES"; else echo "NO"; fi
'@

# ---------- Main loop ----------
foreach ($sub in $subs) {
    Write-Host "=== Subscription: $($sub.Name) ===" -ForegroundColor Green
    try { Set-AzContext -SubscriptionId $sub.Id -ErrorAction Stop | Out-Null }
    catch { Log-Err "Cannot switch to subscription $($sub.Name): $($_.Exception.Message)"; continue }

    $allVMs = @()
    try { $allVMs = Get-AzVM -Status -ErrorAction Stop }
    catch { Log-Err "Get-AzVM failed in $($sub.Name): $($_.Exception.Message)"; continue }

    if ($targetVMs.Count) {
        $vms = $allVMs | Where-Object { $targetVMs -contains $_.Name }
    } else {
        $vms = $allVMs
    }

    Write-Host "    $($vms.Count) matching VMs (of $($allVMs.Count) total in this sub)"
    foreach ($v in $vms) { [void]$notFound.Remove($v.Name) }
    if ($vms.Count -eq 0) { continue }

    # ---- Backup items (modern, no Set-Vault-Context) ----
    $backupItems = @{}
    try {
        $vaults = Get-AzRecoveryServicesVault -ErrorAction SilentlyContinue
        foreach ($v in $vaults) {
            try {
                $containers = Get-AzRecoveryServicesBackupContainer -ContainerType AzureVM -VaultId $v.ID -ErrorAction SilentlyContinue
                foreach ($c in $containers) {
                    $item = Get-AzRecoveryServicesBackupItem -Container $c -WorkloadType AzureVM -VaultId $v.ID -ErrorAction SilentlyContinue
                    if ($item) { $backupItems[$c.FriendlyName.ToLower()] = $item }
                }
            } catch { Log-Err "Vault $($v.Name): $($_.Exception.Message)" }
        }
    } catch { Log-Err "Vault enum failed in $($sub.Name): $($_.Exception.Message)" }

    $i = 0
    foreach ($vm in $vms) {
        $i++
        Write-Host ("  [{0}/{1}] {2}" -f $i, $vms.Count, $vm.Name) -ForegroundColor White

        # ---- Size info (cached) ----
        $sizeInfo = Get-SizeInfo -Location $vm.Location -SkuName $vm.HardwareProfile.VmSize

        # ---- Network ----
        $privIPs=@(); $pubIPs=@(); $nsgs=@(); $subnets=@(); $vnets=@()
        try {
            $nicIds = @($vm.NetworkProfile.NetworkInterfaces.Id)
            foreach ($nicId in $nicIds) {
                try {
                    $nic = Get-AzNetworkInterface -ResourceId $nicId -ErrorAction Stop
                    foreach ($ipc in $nic.IpConfigurations) {
                        if ($ipc.PrivateIpAddress) { $privIPs += $ipc.PrivateIpAddress }
                        if ($ipc.PublicIpAddress) {
                            try {
                                $pip = Get-AzPublicIpAddress -ResourceId $ipc.PublicIpAddress.Id -ErrorAction Stop
                                if ($pip.IpAddress) { $pubIPs += $pip.IpAddress }
                            } catch { Log-Err "  PIP for $($vm.Name): $($_.Exception.Message)" }
                        }
                        if ($ipc.Subnet) {
                            $parts = $ipc.Subnet.Id -split '/'
                            if ($parts.Length -ge 3) {
                                $vnets   += $parts[-3]
                                $subnets += $parts[-1]
                            }
                        }
                    }
                    if ($nic.NetworkSecurityGroup) {
                        $nsgs += ($nic.NetworkSecurityGroup.Id -split '/')[-1]
                    }
                } catch { Log-Err "  NIC for $($vm.Name): $($_.Exception.Message)" }
            }
        } catch { Log-Err "  Network for $($vm.Name): $($_.Exception.Message)" }

        # ---- Disks ----
        $osDisk = $vm.StorageProfile.OsDisk
        $osDiskInfo = $null
        $osDiskSku = ''
        $osDiskEnc = ''
        if ($osDisk -and $osDisk.Name) {
            try {
                $osDiskInfo = Get-AzDisk -ResourceGroupName $vm.ResourceGroupName -DiskName $osDisk.Name -ErrorAction Stop
                $osDiskSku = Get-Prop $osDiskInfo 'Sku.Name'
                $osDiskEnc = Get-Prop $osDiskInfo 'Encryption.Type'
            } catch { Log-Err "  OS disk for $($vm.Name): $($_.Exception.Message)" }
        }

        $dataDisksList = @()
        foreach ($dd in @($vm.StorageProfile.DataDisks)) {
            $dSku = ''
            $dEnc = ''
            try {
                $d = Get-AzDisk -ResourceGroupName $vm.ResourceGroupName -DiskName $dd.Name -ErrorAction Stop
                $dSku = Get-Prop $d 'Sku.Name'
                $dEnc = Get-Prop $d 'Encryption.Type'
            } catch { Log-Err "  Data disk $($dd.Name): $($_.Exception.Message)" }
            $dataDisksList += "$($dd.Name)($($dd.DiskSizeGB)GB/$dSku/LUN$($dd.Lun))"
            $diskInventory.Add([PSCustomObject]@{
                Subscription = $sub.Name
                VMName       = $vm.Name
                DiskName     = $dd.Name
                Role         = 'Data'
                SizeGB       = $dd.DiskSizeGB
                SkuType      = $dSku
                LUN          = $dd.Lun
                Encryption   = $dEnc
                Caching      = $dd.Caching
            })
        }
        if ($osDisk) {
            $diskInventory.Add([PSCustomObject]@{
                Subscription = $sub.Name
                VMName       = $vm.Name
                DiskName     = $osDisk.Name
                Role         = 'OS'
                SizeGB       = $osDisk.DiskSizeGB
                SkuType      = $osDiskSku
                LUN          = $null
                Encryption   = $osDiskEnc
                Caching      = $osDisk.Caching
            })
        }

        # ---- Power / provisioning ----
        $powerState = ''
        $provState  = ''
        try {
            $powerState = ($vm.Statuses | Where-Object Code -like 'PowerState/*' | Select-Object -First 1).DisplayStatus
            $provState  = ($vm.Statuses | Where-Object Code -like 'ProvisioningState/*' | Select-Object -First 1).DisplayStatus
        } catch {}

        $bkp = $backupItems[$vm.Name.ToLower()]

        # ---- Tags ----
        $tagsFlat = ''
        if ($vm.Tags) {
            $tagsFlat = ($vm.Tags.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join '; '
        }

        # ---- In-guest ----
        $hostname=''; $osFull=''; $drives=''; $lastBoot=''; $pendingReboot=''
        $domain=''; $defender=''; $localAdmins=''; $sqlSummary=''

        if (-not $SkipRunCommand -and $powerState -eq 'VM running') {
            try {
                if ($vm.StorageProfile.OsDisk.OsType -eq 'Windows') {
                    $rc = Invoke-AzVMRunCommand -ResourceGroupName $vm.ResourceGroupName `
                          -VMName $vm.Name -CommandId 'RunPowerShellScript' `
                          -ScriptString $winScript -ErrorAction Stop
                    $stdout = ($rc.Value | Where-Object Code -like 'ComponentStatus/StdOut/*').Message
                    if ($stdout) {
                        try {
                            $json = $stdout | ConvertFrom-Json -ErrorAction Stop
                            $hostname      = $json.FQDN
                            $osFull        = "$($json.OSName) (Build $($json.OSBuild))"
                            $drives        = $json.Drives
                            $lastBoot      = $json.LastBootTime
                            $pendingReboot = $json.PendingReboot
                            $domain        = if ($json.DomainJoined) { $json.Domain } else { 'WORKGROUP' }
                            $defender      = "Enabled=$($json.DefenderEnabled); SigDate=$($json.DefenderSigDate)"
                            $localAdmins   = $json.LocalAdmins
                            if ($json.SQL -and $json.SQL -ne 'null' -and $json.SQL -ne '[]') {
                                $sqlDetail = $json.SQL | ConvertFrom-Json -ErrorAction SilentlyContinue
                                if ($sqlDetail) {
                                    if ($sqlDetail -isnot [array]) { $sqlDetail = @($sqlDetail) }
                                    $sqlSummary = ($sqlDetail | ForEach-Object { "$($_.Instance)/$($_.Edition)/$($_.Version)" }) -join '; '
                                    foreach ($s in $sqlDetail) {
                                        $sqlInventory.Add([PSCustomObject]@{
                                            Subscription = $sub.Name
                                            VMName       = $vm.Name
                                            Hostname     = $hostname
                                            Instance     = $s.Instance
                                            Edition      = $s.Edition
                                            Version      = $s.Version
                                            PatchLevel   = $s.PatchLevel
                                            ServiceState = $s.ServiceState
                                            StartMode    = $s.StartMode
                                            Databases    = $s.Databases
                                        })
                                    }
                                }
                            }
                        } catch { Log-Err "  Parse JSON $($vm.Name): $($_.Exception.Message)" }
                    }
                } else {
                    $rc = Invoke-AzVMRunCommand -ResourceGroupName $vm.ResourceGroupName `
                          -VMName $vm.Name -CommandId 'RunShellScript' `
                          -ScriptString $linScript -ErrorAction Stop
                    $stdout = ($rc.Value | Where-Object Code -like 'ComponentStatus/StdOut/*').Message
                    if ($stdout) {
                        $sections = @{}
                        $cur = ''
                        foreach ($line in $stdout -split "`n") {
                            if ($line -match '^---(.+)---$') { $cur = $Matches[1]; $sections[$cur] = @() }
                            elseif ($cur) { $sections[$cur] += $line }
                        }
                        $hostname      = ($sections['HOSTNAME'] -join '').Trim()
                        $osFull        = (($sections['OS'] | Where-Object {$_ -match 'PRETTY_NAME'}) -replace 'PRETTY_NAME=','').Trim('"',' ')
                        $drives        = ($sections['DRIVES'] -join ' | ').Trim()
                        $lastBoot      = ($sections['UPTIME'] -join '').Trim()
                        $pendingReboot = ($sections['PENDINGREBOOT'] -join '').Trim()
                        $sqlText       = ($sections['SQL'] -join ' ').Trim()
                        if ($sqlText -and $sqlText -notmatch 'no_mssql') {
                            $sqlSummary = $sqlText
                            $sqlInventory.Add([PSCustomObject]@{
                                Subscription = $sub.Name
                                VMName       = $vm.Name
                                Hostname     = $hostname
                                Instance     = 'MSSQL-Linux'
                                Edition      = ''
                                Version      = $sqlText
                                PatchLevel   = ''
                                ServiceState = 'active'
                                StartMode    = ''
                                Databases    = ''
                            })
                        }
                    }
                }
            } catch { Log-Err "  RunCommand $($vm.Name): $($_.Exception.Message)" }
        }

        # ---- Build row ----
        $availSet = ''
        if ($vm.AvailabilitySetReference) {
            $availSet = ($vm.AvailabilitySetReference.Id -split '/')[-1]
        }
        $vmIdentityType = Get-Prop $vm 'Identity.Type'
        $bootDiag = Get-Prop $vm 'DiagnosticsProfile.BootDiagnostics.Enabled' $false
        $imgPub = Get-Prop $vm 'StorageProfile.ImageReference.Publisher'
        $imgOff = Get-Prop $vm 'StorageProfile.ImageReference.Offer'
        $imgSku = Get-Prop $vm 'StorageProfile.ImageReference.Sku'

        $vmInventory.Add([PSCustomObject]@{
            Subscription      = $sub.Name
            SubscriptionId    = $sub.Id
            ResourceGroup     = $vm.ResourceGroupName
            VMName            = $vm.Name
            Hostname          = $hostname
            Location          = $vm.Location
            Zone              = ($vm.Zones -join ',')
            AvailabilitySet   = $availSet
            VMSize            = $vm.HardwareProfile.VmSize
            CPUCores          = $sizeInfo.Cores
            RAM_GB            = $sizeInfo.MemGB
            MaxDataDisks      = $sizeInfo.MaxDD
            OSType            = $vm.StorageProfile.OsDisk.OsType
            OSImage           = "$imgPub/$imgOff/$imgSku"
            OSDetail          = $osFull
            Domain            = $domain
            PowerState        = $powerState
            ProvisioningState = $provState
            PrivateIPs        = ($privIPs -join ', ')
            PublicIPs         = ($pubIPs -join ', ')
            VNet              = (($vnets | Select-Object -Unique) -join ', ')
            Subnet            = (($subnets | Select-Object -Unique) -join ', ')
            NSGs              = (($nsgs | Select-Object -Unique) -join ', ')
            OSDiskName        = Get-Prop $osDisk 'Name'
            OSDiskSizeGB      = Get-Prop $osDisk 'DiskSizeGB'
            OSDiskSku         = $osDiskSku
            DataDiskCount     = @($vm.StorageProfile.DataDisks).Count
            DataDisks         = ($dataDisksList -join '; ')
            Drives_InGuest    = $drives
            LastBootTime      = $lastBoot
            PendingReboot     = $pendingReboot
            LicenseType       = $vm.LicenseType
            HybridBenefit     = if ($vm.LicenseType) {'Yes'} else {'No'}
            ManagedIdentity   = $vmIdentityType
            BootDiagEnabled   = $bootDiag
            DiskEncryption    = $osDiskEnc
            BackupEnabled     = if ($bkp) {'Yes'} else {'No'}
            BackupPolicy      = Get-Prop $bkp 'ProtectionPolicyName'
            LastBackupStatus  = Get-Prop $bkp 'LastBackupStatus'
            LastBackupTime    = Get-Prop $bkp 'LastBackupTime'
            DefenderStatus    = $defender
            LocalAdmins       = $localAdmins
            SQLInstalled      = if ($sqlSummary) {'Yes'} else {'No'}
            SQLSummary        = $sqlSummary
            Tags              = $tagsFlat
            CreatedTime       = $vm.TimeCreated
        })
    }
}

# ---------- Export ----------
$vmCsv   = Join-Path $OutputPath 'VMs.csv'
$diskCsv = Join-Path $OutputPath 'Disks.csv'
$sqlCsv  = Join-Path $OutputPath 'SQL.csv'

$vmInventory   | Export-Csv -Path $vmCsv   -NoTypeInformation -Encoding UTF8
$diskInventory | Export-Csv -Path $diskCsv -NoTypeInformation -Encoding UTF8
$sqlInventory  | Export-Csv -Path $sqlCsv  -NoTypeInformation -Encoding UTF8

# Not-found report
if ($targetVMs.Count -and $notFound.Count) {
    $missingPath = Join-Path $OutputPath 'NotFound.txt'
    @($notFound) | Sort-Object | Set-Content -Path $missingPath -Encoding UTF8
    Write-Host "`n!! $($notFound.Count) VM name(s) NOT found in any scanned sub:" -ForegroundColor Yellow
    Write-Host "   See: $missingPath" -ForegroundColor Yellow
}

Write-Host "`n========== DONE ==========" -ForegroundColor Green
Write-Host "VMs:   $($vmInventory.Count)   -> $vmCsv"
Write-Host "Disks: $($diskInventory.Count) -> $diskCsv"
Write-Host "SQL:   $($sqlInventory.Count)  -> $sqlCsv"
if (Test-Path $errorLog) {
    $errCount = (Get-Content $errorLog | Measure-Object -Line).Lines
    Write-Host "Errors logged: $errCount -> $errorLog" -ForegroundColor Yellow
}