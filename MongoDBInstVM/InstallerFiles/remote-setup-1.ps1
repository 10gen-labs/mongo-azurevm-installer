<#
 Copyright 2010-2011 10gen Inc.

 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at

 http://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.
#>

$global:ErrorActionPreference = "Stop"
$drive = "C:\"
$mongodbDownloadUrl = "http://downloads.mongodb.org/win32/mongodb-win32-x86_64-2.0.5.zip"

$mongodbService = "MongoDB2"
$serviceStartRetry = 5
$mongodbRoot = Join-Path $drive "MongoDB"
$mondodbData = Join-Path $mongodbRoot "Data"
$mondodbLog = Join-Path $mongodbRoot "Log"
$mongodbBinaryTarget = Join-Path $mongodbRoot "MongoDBBinaries"
$setupScriptsTarget = Join-Path $mongodbRoot "SetupScripts"
$mongodExe = Join-Path (Join-Path $mongodbBinaryTarget "bin") "mongod.exe"
$mongoExe = Join-Path (Join-Path $mongodbBinaryTarget "bin") "mongo.exe"
$mongodReplInit = Join-Path $setupScriptsTarget "replica-init.cmd"

<# 
    $initTask holds the content of the startup script to initialize the replicaset. 
    This script will be executed via task scheduler. The replicaset is intialized 
    by passing the joson file containing the IP addresses of nodes in the replicaset. 
    This script will be scheduled to execute in every one minute until the intialization 
    succeeded. The result of each execution of mongo replica initialize command will be
    stored in a file named ReplicaSetLog<time>.txt. Overall excution log will be stored
    in replica-init-log.txt.
#>
$initTask = '@echo off' + "`r`n"
$initTask += 'SET "replicalogfile=%~dp0replicalog.txt"' + "`r`n"
$initTask += 'SET "logfile=%~dp0replica-init-log.txt"' + "`r`n"
$initTask += 'IF NOT EXIST "%replicalogfile%" GOTO :runcommand' + "`r`n"
$initTask += 'echo "Found replicalog file" >> %logfile%' + "`r`n"
$initTask += 'SET "tm=%time%"' + "`r`n"
$initTask += 'for /f "tokens=* delims= " %%a in ("%tm%") do set tm=%%a' + "`r`n"
$initTask += 'SET "backupfilename=ReplicaSetLog%tm%"' + "`r`n"
$initTask += 'SET backupfilename=%backupfilename::=-%' + "`r`n"
$initTask += 'SET backupfilename=%backupfilename:.=-%' + "`r`n"
$initTask += 'SET "backupfilename=%backupfilename%.txt"' + "`r`n"
$initTask += 'copy /Y "%~dp0replicalog.txt" %~dp0%backupfilename%' + "`r`n"
$initTask += 'echo "Copied the existing replicalog to %backupfilename%"  >> %logfile%' + "`r`n"
$initTask += 'findstr /m "already initialized" "%replicalogfile%"' + "`r`n"
$initTask += 'if %errorlevel% ==0 (' + "`r`n"
$initTask += 'echo "Found replicalog with which is already in initialized state deleting the task" >> %logfile%' + "`r`n"
$initTask += 'schtasks /delete /tn "replica-init" /f' + "`r`n"
$initTask += 'goto :end' + "`r`n"
$initTask += ')' + "`r`n"
$initTask += 'findstr /m "errmsg" "%replicalogfile%"' + "`r`n"
$initTask += 'if NOT %errorlevel% ==0 (' + "`r`n"
$initTask += 'echo "Found replicalog with no errormsg trying to delete the task" >> %logfile%' + "`r`n"
$initTask += 'schtasks /delete /tn "replica-init" /f' + "`r`n"
$initTask += 'goto :end' + "`r`n"
$initTask += ')' + "`r`n"
$initTask += 'echo "Found replicalog with error message rerunning the initialization" >> %logfile%' + "`r`n"
$initTask += ':runcommand' + "`r`n"
$initTask += 'echo "running command" >> %logfile%' + "`r`n"
$initTask += '%~dp0\..\MongoDBBinaries\bin\mongo.exe %~dp0\initialize.json > %~dp0\replicalog.txt' + "`r`n"
$initTask += ':end' + "`r`n"
$initTask += 'echo "Exiting the script" >> %logfile%' + "`r`n"

<#
   Prepare the json input file content [i.e. the IP addresses of all nodes] for replicaset 
   initialization. 
#>

$thisMongoPort = $null
$monogPorts = @();
$runInit = $False;

$hasReplica = $True;
if ($args.length -eq 2) {
    $hasReplica = $False;
}

$replica = 'rs'
$rsInitCmd = "config = {_id: '<rs>', members:["
$i = 0;
foreach ($arg in $args)
{
    if ($i -ne $args.length - 1) {
        $rsInitCmd += "{"
        $rsInitCmd += "_id:"
        $rsInitCmd += $i
        $rsInitCmd += ", host:"
        $rsInitCmd += "'" + $arg + "'"
        $rsInitCmd += "}, "
        $monogPorts += ($arg.split(":"))[1]

    } else {
        $parts = $arg.split(":")
        if ($parts[0] -eq "YES") {
            $runInit = $True;
        }

        $thisMongoPort = $parts[1]
        if ($parts[2] -ne "NONE") {
            $replica = $parts[2]
        }
    }
    $i++;
}

$rsInitCmd += "]};"
$rsInitCmd += " printjson(rs.initiate(config));"
$rsInitCmd = $rsInitCmd.Replace("<rs>", $replica)

function logStatus {
    param ($message)
    Write-Host "info:   $message" -foregroundcolor "yellow"
}

function logStatus2 {
    param ($message)
    Write-Host "info:   $message" -foregroundcolor "blue"
}

function logErr {
    param ($message)
    Write-Host "error:  $message" -foregroundcolor "red"
}

function logSuccess {
    param ($message)
    Write-Host "info:   $message" -foregroundcolor "green"
}

function logInput {
    param ($message)
    Write-Host "input:  $message" -foregroundcolor "magenta"
}

<#
    Create directory for holding mongodb binaries
#>
if (!(Test-Path -LiteralPath $mongodbBinaryTarget -PathType Leaf)) {
    [IO.Directory]::CreateDirectory($mongodbBinaryTarget)
}

<#
    Create directory for holding replica initialization script, json file
    containing the node IPs, replica initialization logs
#>
if (!(Test-Path -LiteralPath $setupScriptsTarget -PathType Leaf)) {
    [IO.Directory]::CreateDirectory($setupScriptsTarget)
}

<#
    Create directory for mongo data storage
#>
if (!(Test-Path -LiteralPath $mondodbData -PathType Leaf)) {
    [IO.Directory]::CreateDirectory($mondodbData)
}

<#
    Create directory for mongo log storage
#>
if (!(Test-Path -LiteralPath $mondodbLog -PathType Leaf)) {
    [IO.Directory]::CreateDirectory($mondodbLog)
}

<#
    Download the mongodb binaries, extract it to the directory we created for
    holding mongodb binaries
#>
function Download-Binaries {

    if (Test-Path -LiteralPath $mongodExe -PathType Leaf) {
        return
    }
    
    $storageDir = Join-Path $pwd "downloadtemp"
    $webclient = New-Object System.Net.WebClient
    $split = $mongodbDownloadUrl.split("/")
    $fileName = $split[$split.Length-1]
    $filePath = Join-Path $storageDir $fileName
    
    if (!(Test-Path -LiteralPath $storageDir -PathType Container)) {
        New-Item -type directory -path $storageDir | Out-Null
    }
    else {
        logStatus "Cleaning out temporary download directory"
        Remove-Item (Join-Path $storageDir "*") -Recurse -Force
        logStatus "Temporary download directory cleaned"
    }
    
    logStatus "Downloading mongodb binaries. This could take time..."
    $webclient.DownloadFile($mongodbDownloadUrl, $filePath)
    logStatus "mongodb binaries downloaded. Unzipping..."
    
    $shell_app=new-object -com shell.application
    $zip_file = $shell_app.namespace($filePath)
    $destination = $shell_app.namespace($storageDir)
    
    $destination.Copyhere($zip_file.items())
    
    logStatus "Binaries unzipped. Copying to destination"
    $unzipDir = GetUnzipPath($storageDir, $filePath)
    $binPath = dir $unzipDir -recurse | Where-Object { $_.PSIsContainer } | 
        Where-Object { @(Dir "$($_.Fullname)\mongod.exe" -EA SilentlyContinue).Count -eq 1 }

    Copy-Item $binPath.FullName -destination $mongodbBinaryTarget -Recurse

    # Copy license(s) and readme files
    dir $unzipDir -recurse | Where-Object { !$_.PSIsContainer } | 
        Where-Object { $_.Name.StartsWith("README") } | 
        ForEach-Object { Copy-Item $_.FullName -destination $mongodbBinaryTarget }
        
    dir $unzipDir -recurse | Where-Object { !$_.PSIsContainer } | 
        Where-Object { $_.Name.StartsWith("GNU-AGPL") } | 
        ForEach-Object { Copy-Item $_.FullName -destination $mongodbBinaryTarget }
        
    dir $unzipDir -recurse | Where-Object { !$_.PSIsContainer } | 
        Where-Object { $_.Name.StartsWith("THIRD-PARTY-NOTICES") } | 
        ForEach-Object { Copy-Item $_.FullName -destination $mongodbBinaryTarget }

    logStatus "Done copying. Clearing temporary storage directory"
    
    if (Test-Path -LiteralPath $storageDir -PathType Container) {
        Remove-Item -path $storageDir -force -Recurse
    }
}

<#
    Gets the path to extracted location
#>
function GetUnzipPath {
    Param($downloadDir, $downloadFile)
    $dir = Get-Item (Join-Path $storageDir "*") -Exclude $fileName
    return $dir.FullName
}

<#
    Install mongo as a service, retry $retry times if fails
#>
function Install-MongoService {
    param($bindPort)
    logStatus ("Installing Mongo as service " + $mongodbService )
    $mongoLogFile = Join-Path $mondodbLog "Log.log"
    if ($hasReplica) {
        logStatus ("$mongodExe --replSet $replica --port $bindPort --dbpath $mondodbData --logpath  $mongoLogFile --serviceName $mongodbService --serviceDisplayName $mongodbService --install")
        & $mongodExe --replSet $replica --port $bindPort --dbpath $mondodbData --logpath  $mongoLogFile --serviceName $mongodbService --serviceDisplayName $mongodbService --install
    } else {
        logStatus ("$mongodExe --port $bindPort --dbpath $mondodbData --logpath  $mongoLogFile --serviceName $mongodbService --serviceDisplayName $mongodbService --install")
        & $mongodExe --port $bindPort --dbpath $mondodbData --logpath  $mongoLogFile --serviceName $mongodbService --serviceDisplayName $mongodbService --install
    }

    If ($lastexitcode -ne 0)
    {
        $logfile = gci $mondodbLog | sort LastWriteTime | select -last 1
        if($logfile) 
        {
            logStatus2 (Get-Content (Join-Path $mondodbLog $logfile))
        }
    }
    
    logStatus "Trying to start $mongodbService.."
    $success = $false;
    $retry = 0;
    do {
            Start-Sleep -s 12
            try 
            {
                $arrService = Get-Service -Name $mongodbService
                if ($arrService.Status -ne "Running"){
                    Start-Service $mongodbService
                    Write-Host "The service $mongodbService Started.." -foregroundcolor "yellow"
                } else {
                    logStatus "The service $mongodbService is already running.."
                }
                
                $success = $true; 
            }
            catch
            {
                if ( $error[0].Exception -match "Microsoft.PowerShell.Commands.ServiceCommandException")
                {
                    Write-Host $error[0] -foregroundcolor "red"
                    if ($retry -gt 5)
                    {                             
                        $message = "Can not execute Start-Service command. Really exiting with the error: " + $_.Exception.ToString();
                        throw $message;
                    }
                }
                else
                {
                    throw $_.exception
                }
                
                logStatus "Sleeping before $retry retry of Start-Service command"; 
                $retry = $retry + 1;
            }
    } while(!$success);
    
}

logStatus "Start with setup"
Download-Binaries
$initTask | Out-File (Join-Path $setupScriptsTarget "replica-init.cmd") -encoding ASCII
logStatus "Adding firewall exception for mongo-ports"
foreach ($mongoPort in $monogPorts) {
    &netsh advfirewall firewall add rule name="MongoDB-$mongoPort (TCP-In)" dir=in action=allow service=any enable=yes profile=any localport=$mongoPort protocol=tcp
}

logStatus "Applying ACL to the Mongo-Root"
icacls $mongodbRoot /grant Everyone:F /T
logStatus "Writing intialize.json"
$rsInitCmd | Out-File (Join-Path $setupScriptsTarget "initialize.json") -encoding ASCII
$initCmdFile = Join-Path $setupScriptsTarget "initialize.json"
Install-MongoService $thisMongoPort

if (!$hasReplica) {
    logStatus "Replication will not be enabled for single node mongo deployment"
}

if ($runInit -and $hasReplica) {
    logStatus "Trying to initialize replicaset"
    Sleep -s 10
    $initRetry = 1;
    $maxInitRetry = 35
    $initResult = $null
    $search = $null
    do {
        try {
            $initResult = & $mongoExe $initCmdFile 2>&1
            $initResult
            $search = $initResult | select-string 'already initialized'
           if ($search -ne $null) {
                logStatus "Replicaset already initialized"
                break
           }
        } catch [Exception]
        {
           $_.Exception.GetType().FullName
           # force retry
           $initResult = 'err'
        }

        $searchstdError = $initResult | select-string 'connect failed'
        $search = $initResult | select-string 'err'
        if (($search -ne $null) -or ($searchstdError -ne $null) ) {
            if ($initRetry -le $maxInitRetry) {
                $initRetry++;
                # Sleep
                logStatus "Sleeping for some time"
                Sleep -s 40
                logStatus2 "Retrying to initialize replicaset #$initRetry"
            } else {
                logErr "Failed to initialize replica-set after $maxInitRetry, scheduling a task for replica-init and exiting"
                &schtasks /CREATE /TN "replica-init" /SC minute /MO 1 /RL HIGHEST /TR $mongodReplInit /F
                break;
            } 
        } else {
            logSuccess "Replicaset initialized"
            break;
        }
    } while ($True);
} else {
    if ($hasReplica) {
        &schtasks /CREATE /TN "replica-init" /SC minute /MO 1 /RL HIGHEST /TR $mongodReplInit /F
    }
}

logStatus "Done with setup"