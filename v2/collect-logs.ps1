param (
    [parameter(Mandatory=$true)]
    [String] $Destination
)

function Get-WindowsErrors {
    param(
        [String] $Destination
    )

    $path = Join-Path -Path $Destination -ChildPath "windows-errors"
    New-Item -ItemType directory -Path $path | Out-Null

    $reboots = Get-WinEvent -FilterHashtable @{logname='System'; id=1074,1076,2004,6005,6006,6008} `
                   | Select-Object -Property TimeCreated, Id, LevelDisplayName, Message
    $crashes = Get-WinEvent -FilterHashtable @{logname='Application'; ProviderName='Windows Error Reporting'} `
                   | Select-Object -Property TimeCreated, Id, LevelDisplayName, Message
    $hyperVOperational = Get-WinEvent -LogName Microsoft-Windows-Hyper-V-Compute-Operational `
                             | Select-Object -Property TimeCreated, Id, LevelDisplayName, Message `
                             | Sort-Object TimeCreated

    $rebootsPath = Join-Path -Path $path -ChildPath "reboots.txt"
    $crashesPath = Join-Path -Path $path -ChildPath "crashes.txt"
    $hyperVOperationalPath = Join-Path -Path $path -ChildPath "hyperv-operational.txt"

    $reboots | Out-File -FilePath $rebootsPath
    $crashes | Out-File -FilePath $crashesPath
    $hyperVOperational | Out-File -FilePath $hyperVOperationalPath
}

function Get-DockerLogs {
    param(
        [String] $Destination
    )

    $path = Join-Path -Path $Destination -ChildPath "docker-logs"
    New-Item -ItemType directory -Path $path | Out-Null

    Copy-Item -Path "C:\Program Files\Docker\dockerd.log" -Destination $path
    Copy-Item -Path "C:\Program Files\Docker\dockerd-servicewrapper-config.ini" -Destination $path

    $dockerContainers = $(docker ps -a)
    $dockerImages = $(docker images -a)

    $dockerContainersPath = Join-Path -Path $path -ChildPath "docker-containers.txt"
    $dockerImagesPath = Join-Path -Path $path -ChildPath "docker-images.txt"

    $dockerContainers | Out-File -FilePath $dockerContainersPath
    $dockerImages | Out-File -FilePath $dockerImagesPath
}

# Creates a WindowsLogs folder at the required destination
function Get-WindowsLogs {
    param(
        [String] $Destination
    )

    $path = Join-Path -Path $Destination -ChildPath "windows-logs"
    New-Item -ItemType directory -Path $path | Out-Null

    Get-WindowsErrors -Destination $path
    Get-DockerLogs -Destination $path
}

function Get-ServiceLogs {
    param(
        [String[]] $Services,
        [String] $Destination
    )

    foreach ($service in $Services) {
        if (-not (Get-Service -Name $service -ErrorAction SilentlyContinue)) {
            continue
        }

        $path = Join-Path -Path $Destination -ChildPath "$service-logs"
        New-Item -ItemType directory -Path $path | Out-Null

        Copy-Item -Path "C:\k\$service-servicewrapper-config.ini" -Destination $path
        Copy-Item -Path "C:\k\$service*.log" -Destination $path
    }
}

# Creates a KubernetesLogs folder at the required destination
function Get-KubernetesLogs {
    param(
        [String] $Destination
    )

    $ovnServices = @("kubelet", "ovn-kuberntes-node", "ovs-vswitchd", "ovn-controller", "ovsdb-server")
    $flannelServices = @("kubelet", "kube-proxy", "flanneld")

    $path = Join-Path -Path $Destination -ChildPath "kubernetes-logs"
    New-Item -ItemType directory -Path $path | Out-Null

    Get-ServiceLogs -Services $flannelServices -Destination $path
}

function Main {
    $path = Join-Path -Path $Destination -ChildPath "logs"
    New-Item -ItemType directory -Path $path | Out-Null

    Get-WindowsLogs -Destination $path
    Get-KubernetesLogs -Destination  $path

    $archivePath = Join-Path $Destination -ChildPath "logs.zip"
    Compress-Archive -Path $path -CompressionLevel Optimal -DestinationPath $archivePath

    Remove-Item -Recurse -Force -Path $path
}

Main
