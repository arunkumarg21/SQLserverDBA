<#
.SYNOPSIS
    Comprehensive Azure VM Inventory Script
.DESCRIPTION
    Collects Azure-level metadata + in-guest OS/SQL info for all VMs across
    one or more subscriptions. Exports three CSVs: VMs, Disks, SQL.

    Azure data    -> via Az PowerShell modules (no agent needed)
    In-guest data -> via Invoke-AzVMRunCommand (uses VM Agent, no WinRM/SSH)

.REQUIREMENTS
    - PowerShell 5.1+ or 7+
    - Modules: Az.Accounts, Az.Compute, Az.Network, Az.Resources,
               Az.RecoveryServices, Az.Monitor
    - RBAC: Reader on subscription + 'Virtual Machine Contributor' (or
      Microsoft.Compute/virtualMachines/runCommand/action) to run guest scripts.

.USAGE
    .\Get-AzureVMInventory.ps1                          # all accessible subs
    .\Get-AzureVMInventory.ps1 -SubscriptionId xxxx     # one sub
    .\Get-AzureVMInventory.ps1 -SkipRunCommand          # Azure-only, faster
    .\Get-AzureVMInventory.ps1 -OutputPath C:\Inventory
#>

[CmdletBinding()]
param(
    [string[]]$SubscriptionId,
    [string]$OutputPath = (Join-Path $PWD "AzureVMInventory_$(Get-Date -Format 'yyyyMMdd_HHmmss')"),
    [switch]$SkipRunCommand,        # skip in-guest collection (drives/SQL)
    [int]$RunCommandTimeoutSec = 180
)

# ---------- Setup ----------
$ErrorActionPreference = 'Continue'
if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath | Out-Null }

Write-Host "==> Output: $OutputPath" -ForegroundColor Cyan

# Ensure logged in
if (-not (Get-AzContext)) {
    Write-Host "Not logged in. Running Connect-AzAccount..." -ForegroundColor Yellow
    Connect-AzAccount | Out-Null
}

# Pick subs
if ($SubscriptionId) {
    $subs = Get-AzSubscription -SubscriptionId $SubscriptionId
} else {
    $subs = Get-AzSubscription | Where-Object { $_.State -eq 'Enabled' }
}

$vmInventory   = New-Object System.Collections.Generic.List[object]
$diskInventory = New-Object System.Collections.Generic.List[object]
$sqlInventory  = New-Object System.Collections.Generic.List[object]

# ---------- In-guest scripts ----------

# Windows: hostname, OS, drives, SQL, pending reboot, last boot, domain, patches
$winScript = @'
$ErrorActionPreference = 'SilentlyContinue'
$out = [ordered]@{}

$cs = Get-CimInstance Win32_ComputerSystem
$os = Get-CimInstance Win32_OperatingSystem
$out.Hostname       = $env:COMPUTERNAME
$out.FQDN           = "$($cs.DNSHostName).$($cs.Domain)"
$out.DomainJoined   = $cs.PartOfDomain
$out.Domain         = $cs.Domain
$out.OSName         = $os.Caption
$out.OSVersion      = $os.Version
$out.OSBuild        = $os.BuildNumber
$out.OSArch         = $os.OSArchitecture
$out.LastBootTime   = $os.LastBootUpTime
$out.TimeZone       = (Get-TimeZone).Id
$out.InstallDate    = $os.InstallDate

# Drives
$drives = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" |
    ForEach-Object {
        "{0}|{1}|{2:N1}GB|{3:N1}GB|{4:N1}%" -f $_.DeviceID, $_.FileSystem,
            ($_.Size/1GB), ($_.FreeSpace/1GB),
            (($_.Size - $_.FreeSpace)/$_.Size*100)
    }
$out.Drives = ($drives -join '; ')

# Pending reboot
$pending = $false
if (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending' -EA SilentlyContinue) {$pending=$true}
if (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired' -EA SilentlyContinue) {$pending=$true}
$out.PendingReboot = $pending

# Last patch
$out.LastHotfix = (Get-HotFix | Sort-Object InstalledOn -Descending | Select-Object -First 1 -ExpandProperty InstalledOn)

# Defender
$def = Get-MpComputerStatus
$out.DefenderEnabled = $def.AntivirusEnabled
$out.DefenderSigDate = $def.AntivirusSignatureLastUpdated

# Local admins
$out.LocalAdmins = (Get-LocalGroupMember -Group 'Administrators' -EA SilentlyContinue | Select-Object -Expand Name) -join '; '

# --- SQL Server ---
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
            Instance   = $instName
            Edition    = $setup.Edition
            Version    = $setup.Version
            PatchLevel = $setup.PatchLevel
            ServiceState = $svc.Status
            StartMode  = $svc.StartType
            Databases  = $dbs
        }
    }
}
$out.SQL = ($sqlData | ConvertTo-Json -Compress -Depth 3)

# Emit as JSON for easy parsing back in the script
$out | ConvertTo-Json -Compress -Depth 4
'@

# Linux: hostname, OS, drives, mount points, last boot, SQL (mssql-server)
$linScript = @'
echo "---HOSTNAME---"; hostname -f 2>/dev/null || hostname
echo "---OS---"; cat /etc/os-release 2>/dev/null | grep -E "^(NAME|VERSION|PRETTY_NAME)="
echo "---KERNEL---"; uname -r
echo "---UPTIME---"; uptime -s 2>/dev/null
echo "---TZ---"; timedatectl 2>/dev/null | grep "Time zone"
echo "---DRIVES---"; df -hPT --output=source,fstype,size,used,avail,pcent,target | grep -vE "tmpfs|udev|overlay|squashfs"
echo "---LASTUPDATE---"
if command -v rpm >/dev/null; then rpm -qa --last | head -1
elif command -v dpkg >/dev/null; then ls -lt /var/log/dpkg.log 2>/dev/null | head -1
fi
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

    $vms = Get-AzVM -Status
    Write-Host "Found $($vms.Count) VMs"

    # Backup items lookup (once per sub)
    $backupItems = @{}
    try {
        $vaults = Get-AzRecoveryServicesVault
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
            # Size info -> CPU/RAM
            $size = Get-AzVMSize -Location $vm.Location | Where-Object Name -eq $vm.HardwareProfile.VmSize | Select-Object -First 1

            # NICs / IPs / NSG
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
                        $sub_parts = $ipc.Subnet.Id -split '/'
                        $vnets   += $sub_parts[-3]
                        $subnets += $sub_parts[-1]
                    }
                }
                if ($nic.NetworkSecurityGroup) {
                    $nsgs += ($nic.NetworkSecurityGroup.Id -split '/')[-1]
                }
            }

            # Disks
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
            # OS disk row
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

            # Power / provisioning state
            $powerState = ($vm.Statuses | Where-Object Code -like 'PowerState/*' | Select-Object -First 1).DisplayStatus
            $provState  = ($vm.Statuses | Where-Object Code -like 'ProvisioningState/*' | Select-Object -First 1).DisplayStatus

            # Backup
            $bkp = $backupItems[$vm.Name.ToLower()]

            # Tags flat
            $tagsFlat = ($vm.Tags.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join '; '

            # --- In-guest collection ---
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

            # Build row
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

Write-Host "`n==> Done." -ForegroundColor Green
Write-Host "VMs:   $($vmInventory.Count)   -> $vmCsv"
Write-Host "Disks: $($diskInventory.Count) -> $diskCsv"
Write-Host "SQL:   $($sqlInventory.Count)  -> $sqlCsv"
