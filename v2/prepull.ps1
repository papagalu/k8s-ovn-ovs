# Script file to create tmp directory in windows nodes

mkdir c:\tmp

Write-Host "Prepulling all test images"

docker pull e2eteam/busybox:1.29

[System.Environment]::SetEnvironmentVariable('DOCKER_API_VERSION', "1.39", [System.EnvironmentVariableTarget]::Machine)
