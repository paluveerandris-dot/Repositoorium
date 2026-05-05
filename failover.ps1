$PrimaryVM = "Zabbix-Primary"
$StandbyVM = "Zabbix-Standby"
$PrimaryIP = "192.168.0.20"
$LogFile = "C:\HyperV\Scripts\failover.log"
$ExportPath = "E:\loputoo\export"
$NewStandbyVM = "Zabbix-Standby-New"
$VmStorePath = "E:\HyperV\VMs"
$VhdStorePath = "E:\HyperV\VHDs"
$SwitchName = "Default Switch"
$UnreachableThreshold = 2
$RetryDelaySeconds = 3

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $LogFile -Value "$timestamp - $Message"
}

function Test-HostReachable {
    param(
        [string]$ComputerName,
        [int]$Attempts,
        [int]$DelaySeconds
    )

    for ($i = 1; $i -le $Attempts; $i++) {
        if (Test-Connection -ComputerName $ComputerName -Count 2 -Quiet) {
            return $true
        }
        if ($i -lt $Attempts) {
            Start-Sleep -Seconds $DelaySeconds
        }
    }

    return $false
}

function Test-VMHeartbeatReachable {
    param(
        [string]$VmName,
        [int]$Attempts,
        [int]$DelaySeconds
    )

    for ($i = 1; $i -le $Attempts; $i++) {
        $heartbeat = Get-VMIntegrationService -VMName $VmName -Name "Heartbeat" -ErrorAction SilentlyContinue
        if ($heartbeat -and $heartbeat.PrimaryStatusDescription -eq "OK") {
            return $true
        }
        if ($i -lt $Attempts) {
            Start-Sleep -Seconds $DelaySeconds
        }
    }

    return $false
}

function Stop-UnreachableVM {
    param([string]$VmName)

    $state = (Get-VM -Name $VmName -ErrorAction Stop).State
    if ($state -eq "Running") {
        Write-Log "VM '$VmName' is running but unreachable. Stopping VM."
        Stop-VM -Name $VmName -Force -ErrorAction Stop
        Write-Log "VM '$VmName' stopped."
    }
}

function New-StandbyFromExport {
    param(
        [string]$ExportPath,
        [string]$NewVmName,
        [string]$OldStandbyVmName,
        [string]$VmStorePath,
        [string]$VhdStorePath,
        [string]$SwitchName
    )

    try {
        $existingVm = Get-VM -Name $NewVmName -ErrorAction SilentlyContinue
        if ($existingVm) {
            Write-Log "New standby VM '$NewVmName' already exists. Skipping creation."
            return
        }

        $vmcx = Get-ChildItem -Path $ExportPath -Recurse -Filter *.vmcx -ErrorAction Stop | Select-Object -First 1
        if (-not $vmcx) {
            Write-Log "No .vmcx file found under export path: $ExportPath"
            return
        }

        Write-Log "Importing new standby VM from export: $($vmcx.FullName)"
        $timestampSuffix = Get-Date -Format "yyyyMMdd-HHmmss"
        $vmStorePathRun = Join-Path -Path $VmStorePath -ChildPath "$NewVmName-$timestampSuffix"
        $vhdStorePathRun = Join-Path -Path $VhdStorePath -ChildPath "$NewVmName-$timestampSuffix"

        New-Item -Path $vmStorePathRun -ItemType Directory -Force | Out-Null
        New-Item -Path $vhdStorePathRun -ItemType Directory -Force | Out-Null

        Write-Log "Using VM path: $vmStorePathRun"
        Write-Log "Using VHD path: $vhdStorePathRun"

        $importedVm = Import-VM -Path $vmcx.FullName -Copy -GenerateNewId -VirtualMachinePath $vmStorePathRun -VhdDestinationPath $vhdStorePathRun -ErrorAction Stop
        Rename-VM -VM $importedVm -NewName $NewVmName -ErrorAction Stop

        if ($SwitchName) {
            Get-VMNetworkAdapter -VMName $NewVmName -ErrorAction Stop | Connect-VMNetworkAdapter -SwitchName $SwitchName -ErrorAction Stop
        }

        # Remove inherited ISO attachments from exported VM before start.
        $dvdDrives = Get-VMDvdDrive -VMName $NewVmName -ErrorAction SilentlyContinue
        if ($dvdDrives) {
            foreach ($dvdDrive in $dvdDrives) {
                if ($dvdDrive.Path) {
                    Write-Log "Clearing DVD ISO path on '$NewVmName': $($dvdDrive.Path)"
                    Set-VMDvdDrive -VMName $NewVmName -ControllerNumber $dvdDrive.ControllerNumber -ControllerLocation $dvdDrive.ControllerLocation -Path $null -ErrorAction Stop
                }
            }
        }

        Write-Log "New standby VM created successfully: $NewVmName"
        Write-Log "Starting new standby VM: $NewVmName"
        Start-VM -Name $NewVmName -ErrorAction Stop | Out-Null
        Start-Sleep -Seconds 10
        $newStandbyState = (Get-VM -Name $NewVmName -ErrorAction Stop).State
        Write-Log "New standby VM state after start: $newStandbyState"

        if ($newStandbyState -eq "Running") {
            $newStandbyReachable = Test-VMHeartbeatReachable -VmName $NewVmName -Attempts $UnreachableThreshold -DelaySeconds $RetryDelaySeconds
            if ($newStandbyReachable) {
                Write-Log "New standby VM heartbeat is reachable: $NewVmName"
            } else {
                Write-Log "New standby VM heartbeat is not reachable: $NewVmName"
            }

            $oldStandbyState = (Get-VM -Name $OldStandbyVmName -ErrorAction SilentlyContinue).State
            if ($oldStandbyState -eq "Running") {
                Write-Log "New standby is active. Stopping old standby VM: $OldStandbyVmName"
                Stop-VM -Name $OldStandbyVmName -Force -ErrorAction Stop
                Write-Log "Old standby VM stopped: $OldStandbyVmName"
            } elseif ($oldStandbyState) {
                Write-Log "Old standby VM already not running: $OldStandbyVmName (state: $oldStandbyState)"
            }
        }
    }
    catch {
        Write-Log "Failed to create new standby VM '$NewVmName'. Error: $($_.Exception.Message)"
    }
}

Write-Log "Failover check started."

$primaryVmState = (Get-VM -Name $PrimaryVM -ErrorAction Stop).State
$standbyVmState = (Get-VM -Name $StandbyVM -ErrorAction Stop).State

Write-Log "Primary VM state: $primaryVmState"
Write-Log "Standby VM state: $standbyVmState"

$primaryReachable = $false
if ($primaryVmState -eq "Running") {
    $primaryReachable = Test-HostReachable -ComputerName $PrimaryIP -Attempts $UnreachableThreshold -DelaySeconds $RetryDelaySeconds
}

if ($primaryReachable) {
    Write-Log "Primary reachable at $PrimaryIP. No action needed."
    exit
}

Write-Log "Primary is not reachable."
if ($primaryVmState -eq "Running") {
    Stop-UnreachableVM -VmName $PrimaryVM
}

if ($standbyVmState -eq "Running") {
    $standbyReachable = Test-VMHeartbeatReachable -VmName $StandbyVM -Attempts $UnreachableThreshold -DelaySeconds $RetryDelaySeconds
    if ($standbyReachable) {
    Write-Log "Standby already running. No action taken."
    exit
    }

    Write-Log "Standby is not reachable."
    Stop-UnreachableVM -VmName $StandbyVM
}

Write-Log "Starting standby VM: $StandbyVM"
Write-Log "Standby is not reachable."
Start-VM -Name $StandbyVM | Out-Null

Start-Sleep -Seconds 20

$standbyVmStateAfter = (Get-VM -Name $StandbyVM).State
Write-Log "Standby state after start: $standbyVmStateAfter"

if ($standbyVmStateAfter -eq "Running") {
    Write-Log "Attempting to create new standby VM from export."
    New-StandbyFromExport -ExportPath $ExportPath -NewVmName $NewStandbyVM -OldStandbyVmName $StandbyVM -VmStorePath $VmStorePath -VhdStorePath $VhdStorePath -SwitchName $SwitchName
} else {
    Write-Log "Standby did not reach Running state; skipping new standby creation."
}