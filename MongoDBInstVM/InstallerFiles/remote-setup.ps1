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

Add-Type -AssemblyName System.ServiceModel.Web, System.Runtime.Serialization

$mylocation =  [System.IO.Path]::GetDirectoryName($MyInvocation.MyCommand.Path)
Set-Location $mylocation

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

if ($args.Count -ne 1) {
    Write-Host "`r`n  USAGE: remote-setup.ps1 <password>`r`n" -foregroundcolor "green"
    exit 1
}

$password = $args[0]
<#
    Reads the configuration/Connection file config.json and ConnectionStrings.json
#>
function get-ConnectionAndConfig
{
   try
   {
        [hashtable]$result = @{} 
        $jsonString = Get-Content (Join-Path $pwd "config.json")
        $bytes = [Byte[]][System.Text.Encoding]::ASCII.GetBytes($jsonString)
        $jsonReader = [System.Runtime.Serialization.Json.JsonReaderWriterFactory]::CreateJsonReader($bytes, [System.Xml.XmlDictionaryReaderQuotas]::Max)
        $xml = New-Object Xml.XmlDocument
        $xml.Load($jsonReader)
        $result.dnsPrefix = ($xml | Select-Xml '//root/item/DNS/item/info/name')
        $result.dns = ($xml | Select-Xml '//root/item/SSH/item/info/host')
        $result.user = ($xml | Select-Xml '//root/item/SSH/item/info/user')
        $result.ports = @();
        $xml | Select-Xml -XPath '//root/item/SSH/item/info/ports/item' | Foreach {$result.ports += $_.Node.InnerText}
        $result.ips = @();
        $xml | Select-Xml -XPath '//root/item/VMS/item/info/ips/item' | Foreach {$result.ips += $_.Node.InnerText}

        $connectionStringFile = "connectionStrings-" + $result.dnsPrefix + ".json"
        logStatus "Reading connection string file $connectionStringFile"
        $jsonString = Get-Content (Join-Path $pwd $connectionStringFile)
        $bytes = [Byte[]][System.Text.Encoding]::ASCII.GetBytes($jsonString)
        $jsonReader2 = [System.Runtime.Serialization.Json.JsonReaderWriterFactory]::CreateJsonReader($bytes, [System.Xml.XmlDictionaryReaderQuotas]::Max)
        $xml = New-Object Xml.XmlDocument
        $xml.Load($jsonReader2)

        $result.mongoUrls = @();
        $xml | Select-Xml -XPath '//root/item/Mongo/item/info/connectionUrl/item' | Foreach {$result.mongoUrls += $_.Node.InnerText}
        $result.replica = ($xml | Select-Xml '//root/item/Mongo/item/info/ReplicaSetName')
        return $result;
        
   }
   finally
   {
        $jsonReader.Close()
        $jsonReader2.Close()
   }
}

logStatus "Reading the configuration file.."
$result = get-ConnectionAndConfig

$dnsPrefix = $result.Get_Item("dnsPrefix")
logStatus ("DNS: " + $result.Get_Item("dns"))
logStatus ("VM IP Addresses:" + $result.Get_Item("ips"))
$secpasswd = ConvertTo-SecureString $password -AsPlainText -Force
$cred = New-Object System.Management.Automation.PSCredential ($result.Get_Item("user"), $secpasswd)
# After VM's are in ready state it takes some time to reach the VM in a state in which
# it can accept the request, so waiting for 30 seconds
 Start-Sleep -s 30
# Runs the remote setup script in each VM, do retry if the connection fails.
$k = 1
$m = 0
foreach ($port in $result.Get_Item("ports")) {
  logStatus ("Running setup on " + $result.Get_Item("dns") + ":" + $port)
  $mongoUrls = $result.Get_Item("mongoUrls");
  $currentMongo = $mongoUrls[$m]
  logStatus ("Mongo endpoint: " + $currentMongo)
  $mongoHostPort = $currentMongo.split(":")
  $m++
  $retry = 0;
  do {
        $success = $false;
        $replica = "NONE"
        if ($result.Get_Item("replica")) {
            $replica = $result.replica
        }

        $extraArg = $null
        if($k -eq $result.ports.length) {
            $extraArg = "YES" + ":" + $mongoHostPort[1] + ":" + $replica;
        } else {
           $extraArg = "NO" + ":" + $mongoHostPort[1] + ":" + $replica;
        }

        $params = $mongoUrls
        $params += $extraArg

        try 
        {
            Invoke-Command -ComputerName $result.Get_Item("dns") -Port $port -Credential $cred -FilePath remote-setup-1.ps1 -ArgumentList ($params) -ErrorAction Stop
            $success = $true
            $k++;
        }
        catch [Exception]
        {
            If ($_.Exception -is [System.Management.Automation.Remoting.PSRemotingTransportException]) {
                if ($retry -ge 10) {
                    $_.Exception.GetType().FullName
                    logeErr ("Connection to WinRM service running on $port failed after $retry retry, moving to next VM")
                    $k++;
                    break
                } else {
                    logStatus2 ("Connection to WinRM service running on $port failed.. Retrying#" + $retry)
                    Start-Sleep -s (20 + $retry*5) 
                    $retry++;
                }
            } else {
                throw $_.Exception
            }
        }
     } while (!$success);
}

logSuccess "Connection details of mongo instances, RDP and remoting are stored in connectionString-$dnsPrefix.json"