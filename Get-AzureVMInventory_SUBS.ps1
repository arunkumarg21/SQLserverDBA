<#
.SYNOPSIS
    Azure VM Inventory Script — with flexible input.

.DESCRIPTION
    Collects Azure-level metadata + in-guest OS/SQL info.
    Input can come from:
      - a text file of VM names           (-VMListFile)
      - a text file of subscription IDs   (-SubscriptionFile)
      - inline arrays                     (-VMName, -SubscriptionId)
      - nothing (process everything accessible)

    Matching is case-insensitive on the Azure VM resource name.
    If you give just a VM list, the script searches every accessible
    subscription and finds them automatically.

    Azure data    -> Az PowerShell modules
    In-guest data -> Invoke-AzVMRunCommand (uses VM Agent)

.REQUIREMENTS
    PowerShell 5.1+ / 7+
    Modules: Az.Accounts, Az.Compute, Az.Network, Az.Resources,
             Az.RecoveryServices

.EXAMPLES
    # Everything you have access to
    .\Get-AzureVMInventory.ps1

    # Only specific VMs (search all subs)
    .\Get-AzureVMInventory.ps1 -VMListFile .\vms.txt

    # Only specific subscriptions
    .\Get-AzureVMInventory.ps1 -SubscriptionFile .\subs.txt

    # Specific VMs within specific subs
    .\Get-AzureVMInventory.ps1 -VMListFile .\vms.txt -SubscriptionFile .\subs.txt

    # Skip in-guest collection (Azure data only, very fast)
    .\Get-AzureVMInventory.ps1 -VMListFile .\vms.txt -SkipRunCommand

    # Inline names instead of files
    .\Get-AzureVMInventory.ps1 -VMName vm-sql-01,vm-app-02
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

# ---------- Setup ----------
$ErrorActionPreference = 'Continue'
if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath | Out-Null }

Write-Host "==> Output: $OutputPath" -ForegroundColor Cyan

# ---------- Helper: read a list file (strip comments / blanks / whitespace) ----------
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

$targetVMs  = $targetVMs  | Select-Object -Unique
$targetSubs = $targetSubs | Select-Object -Unique

if ($targetVMs.Count)  { Write-Host "==> Filtering to $($targetVMs.Count) VM name(s)" -ForegroundColor Cyan }
if ($targetSubs.Count) { Write-Host "==> Filtering to $($targetSubs.Count) subscription(s)" -ForegroundColor Cyan }
if (-not $targetVMs.Count -and -not $targetSubs.Count) {
    Write-Host "==> No filters; processing ALL accessible VMs in ALL subscriptions" -ForegroundColor Yellow
}

# ---------- Ensure logged in ----------
if (-not (Get-AzContext)) {
    Write-Host "Not logged in. Running Connect-AzAccount..." -ForegroundColor Yellow
    Connect-AzAccount | Out-Null
}

# ---------- Pick subscriptions ----------
if ($targetSubs.Count) {
    # accept both IDs and names
    $allSubs = Get-AzSubscription
    $subs = @()
    foreach ($s in $targetSubs) {
        $match = $allSubs | Where-Object { $_.Id -eq $s -or $_.Name -eq $s }
        if ($match) { $subs += $match }
        else { Write-Warning "Subscription not found / no access: $s" }
    }
} else {
    $subs = Get-AzSubscription | Where-Object { $_.State -eq 'Enabled' }
}

$subs = $subs | Sort-Object Id -Unique
Write-Host "==> Scanning $($subs.Count) subscription(s)" -ForegroundColor Cyan

$vmInventory   = New-Object System.Collections.Generic.List[object]
$diskInventory = New-Object System.Collections.Generic.List[object]
$sqlInventory  = New-Object System.Collections.Generic.List[object]
$notFound      = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($n in $targetVMs) { [void]$notFound.Add($n) }

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

$drives = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" |
    ForEach-Object {
        "{0}|{1}|{2:N1}GB|{3:N1}GB|{4:N1}%" -f $_.DeviceID, $_.FileSystem,
            ($_.Size/1GB), ($_.FreeSpace/1GB),
            (($_.Size - $_.FreeSpace)/$_.Size*100)
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

# SQL Server
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
    Write-Host "`n=== Subscription: $($sub.Name) ===" -ForegroundColor Green
    Set-AzContext -SubscriptionId $sub.Id | Out-Null

    $allVMs = Get-AzVM -Status

    # Filter by VM list if provided
    if ($targetVMs.Count) {
        $vms = $allVMs | Where-Object { $targetVMs -contains $_.Name }
    } else {
        $vms = $allVMs
    }

    Write-Host "Found $($vms.Count) matching VMs (of $($allVMs.Count) total in this sub)"

    # Mark which target names we found in this sub
    foreach ($v in $vms) { [void]$notFound.Remove($v.Name) }

    if ($vms.Count -eq 0) { continue }

    # Backup items lookup (once per sub, only if VMs to process)
    $backupItems = @{}
    try {
        $vaults = Get-AzRecoveryServicesVault -EA SilentlyContinue
        foreach ($v in $vaults) {
            Set-AzRecoveryServicesVaultContext -Vault $v -EA SilentlyContinue | Out-Null
            $containers = Get-AzRecoveryServicesBackupContainer -ContainerType AzureVM -EA SilentlyContinue
            foreach ($c in $containers) {
                $item = Get-AzRecoveryServicesBackupItem -Container $c -WorkloadType AzureVM -EA SilentlyContinue
                if ($item) { $backupItems[$c.FriendlyName.ToLower()] = $item }
            }
        }
    } catch { Write-Warning "Backup vault enum failed: $_" }

    foreach ($vm in $vms) {
        Write-Host "  -> $($vm.Name)" -ForegroundColor White
        try {
            $size = Get-AzVMSize -Location $vm.Location | Where-Object Name -eq $vm.HardwareProfile.VmSize | Select-Object -First 1

            $nicIds = $vm.NetworkProfile.NetworkInterfaces.Id
            $privIPs=@(); $pubIPs=@(); $nsgs=@(); $subnets=@(); $vnets=@()
            foreach ($nicId in $nicIds) {
                $nic = Get-AzNetworkInterface -ResourceId $nicId
                foreach ($ipc in $nic.IpConfigurations) {
                    $privIPs += $ipc.PrivateIpAddress
                    if ($ipc.PublicIpAddress) {
                        $pip = Get-AzPublicIpAddress -ResourceId $ipc.PublicIpAddress.Id
                        $pubIPs += $pip.IpAddress
                    }
                    if ($ipc.Subnet) {
                        $parts = $ipc.Subnet.Id -split '/'
                        $vnets   += $parts[-3]
                        $subnets += $parts[-1]
                    }
                }
                if ($nic.NetworkSecurityGroup) {
                    $nsgs += ($nic.NetworkSecurityGroup.Id -split '/')[-1]
                }
            }

            $osDisk = $vm.StorageProfile.OsDisk
            $osDiskInfo = Get-AzDisk -ResourceGroupName $vm.ResourceGroupName -DiskName $osDisk.Name -EA SilentlyContinue

            $dataDisks = @()
            foreach ($dd in $vm.StorageProfile.DataDisks) {
                $d = Get-AzDisk -ResourceGroupName $vm.ResourceGroupName -DiskName $dd.Name -EA SilentlyContinue
                $dataDisks += "$($dd.Name)($($dd.DiskSizeGB)GB/$($d.Sku.Name)/LUN$($dd.Lun))"
                $diskInventory.Add([PSCustomObject]@{
                    Subscription = $sub.Name
                    VMName       = $vm.Name
                    DiskName     = $dd.Name
                    Role         = 'Data'
                    SizeGB       = $dd.DiskSizeGB
                    SkuType      = $d.Sku.Name
                    LUN          = $dd.Lun
                    Encryption   = $d.Encryption.Type
                    Caching      = $dd.Caching
                })
            }
            $diskInventory.Add([PSCustomObject]@{
                Subscription = $sub.Name
                VMName       = $vm.Name
                DiskName     = $osDisk.Name
                Role         = 'OS'
                SizeGB       = $osDisk.DiskSizeGB
                SkuType      = $osDiskInfo.Sku.Name
                LUN          = $null
                Encryption   = $osDiskInfo.Encryption.Type
                Caching      = $osDisk.Caching
            })

            $powerState = ($vm.Statuses | Where-Object Code -like 'PowerState/*' | Select-Object -First 1).DisplayStatus
            $provState  = ($vm.Statuses | Where-Object Code -like 'ProvisioningState/*' | Select-Object -First 1).DisplayStatus

            $bkp = $backupItems[$vm.Name.ToLower()]
            $tagsFlat = ($vm.Tags.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join '; '

            $hostname=''; $osFull=''; $drives=''; $lastBoot=''; $pendingReboot=''
            $domain=''; $defender=''; $localAdmins=''; $sqlSummary=''; $sqlDetail=$null

            if (-not $SkipRunCommand -and $powerState -eq 'VM running') {
                try {
                    if ($vm.StorageProfile.OsDisk.OsType -eq 'Windows') {
                        $rc = Invoke-AzVMRunCommand -ResourceGroupName $vm.ResourceGroupName `
                              -VMName $vm.Name -CommandId 'RunPowerShellScript' `
                              -ScriptString $winScript -EA Stop
                        $stdout = ($rc.Value | Where-Object Code -like 'ComponentStatus/StdOut/*').Message
                        if ($stdout) {
                            try {
                                $json = $stdout | ConvertFrom-Json
                                $hostname      = $json.FQDN
                                $osFull        = "$($json.OSName) (Build $($json.OSBuild))"
                                $drives        = $json.Drives
                                $lastBoot      = $json.LastBootTime
                                $pendingReboot = $json.PendingReboot
                                $domain        = if ($json.DomainJoined) { $json.Domain } else { 'WORKGROUP' }
                                $defender      = "Enabled=$($json.DefenderEnabled); SigDate=$($json.DefenderSigDate)"
                                $localAdmins   = $json.LocalAdmins
                                if ($json.SQL -and $json.SQL -ne 'null' -and $json.SQL -ne '[]') {
                                    $sqlDetail = $json.SQL | ConvertFrom-Json
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
                            } catch { Write-Warning "Parse win JSON failed for $($vm.Name): $_" }
                        }
                    } else {
                        $rc = Invoke-AzVMRunCommand -ResourceGroupName $vm.ResourceGroupName `
                              -VMName $vm.Name -CommandId 'RunShellScript' `
                              -ScriptString $linScript -EA Stop
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
                } catch {
                    Write-Warning "RunCommand failed for $($vm.Name): $($_.Exception.Message)"
                }
            }

            $vmInventory.Add([PSCustomObject]@{
                Subscription      = $sub.Name
                SubscriptionId    = $sub.Id
                ResourceGroup     = $vm.ResourceGroupName
                VMName            = $vm.Name
                Hostname          = $hostname
                Location          = $vm.Location
                Zone              = ($vm.Zones -join ',')
                AvailabilitySet   = if ($vm.AvailabilitySetReference) {($vm.AvailabilitySetReference.Id -split '/')[-1]} else {''}
                VMSize            = $vm.HardwareProfile.VmSize
                CPUCores          = $size.NumberOfCores
                RAM_GB            = [math]::Round($size.MemoryInMB / 1024, 1)
                MaxDataDisks      = $size.MaxDataDiskCount
                OSType            = $vm.StorageProfile.OsDisk.OsType
                OSImage           = "$($vm.StorageProfile.ImageReference.Publisher)/$($vm.StorageProfile.ImageReference.Offer)/$($vm.StorageProfile.ImageReference.Sku)"
                OSDetail          = $osFull
                Domain            = $domain
                PowerState        = $powerState
                ProvisioningState = $provState
                PrivateIPs        = ($privIPs -join ', ')
                PublicIPs         = ($pubIPs -join ', ')
                VNet              = (($vnets | Select-Object -Unique) -join ', ')
                Subnet            = (($subnets | Select-Object -Unique) -join ', ')
                NSGs              = (($nsgs | Select-Object -Unique) -join ', ')
                OSDiskName        = $osDisk.Name
                OSDiskSizeGB      = $osDisk.DiskSizeGB
                OSDiskSku         = $osDiskInfo.Sku.Name
                DataDiskCount     = $vm.StorageProfile.DataDisks.Count
                DataDisks         = ($dataDisks -join '; ')
                Drives_InGuest    = $drives
                LastBootTime      = $lastBoot
                PendingReboot     = $pendingReboot
                LicenseType       = $vm.LicenseType
                HybridBenefit     = if ($vm.LicenseType) {'Yes'} else {'No'}
                ManagedIdentity   = $vm.Identity.Type
                BootDiagEnabled   = $vm.DiagnosticsProfile.BootDiagnostics.Enabled
                DiskEncryption    = $osDiskInfo.Encryption.Type
                BackupEnabled     = if ($bkp) {'Yes'} else {'No'}
                BackupPolicy      = if ($bkp) {$bkp.ProtectionPolicyName} else {''}
                LastBackupStatus  = if ($bkp) {$bkp.LastBackupStatus} else {''}
                LastBackupTime    = if ($bkp) {$bkp.LastBackupTime} else {''}
                DefenderStatus    = $defender
                LocalAdmins       = $localAdmins
                SQLInstalled      = if ($sqlSummary) {'Yes'} else {'No'}
                SQLSummary        = $sqlSummary
                Tags              = $tagsFlat
                CreatedTime       = $vm.TimeCreated
            })
        } catch {
            Write-Warning "Failed processing $($vm.Name): $_"
        }
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
    $notFound | Sort-Object | Set-Content -Path $missingPath -Encoding UTF8
    Write-Host "`n!! $($notFound.Count) VM name(s) in the input were NOT found in any scanned subscription." -ForegroundColor Yellow
    Write-Host "   See: $missingPath" -ForegroundColor Yellow
}

Write-Host "`n==> Done." -ForegroundColor Green
Write-Host "VMs:   $($vmInventory.Count)   -> $vmCsv"
Write-Host "Disks: $($diskInventory.Count) -> $diskCsv"
Write-Host "SQL:   $($sqlInventory.Count)  -> $sqlCsv"
