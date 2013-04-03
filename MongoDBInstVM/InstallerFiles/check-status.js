/**
* Copyright 2010-2011 10gen Inc.
*
* Licensed under the Apache License, Version 2.0 (the "License");
* you may not use this file except in compliance with the License.
* You may obtain a copy of the License at
*
* http://www.apache.org/licenses/LICENSE-2.0
*
* Unless required by applicable law or agreed to in writing, software
* distributed under the License is distributed on an "AS IS" BASIS,
* WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
* See the License for the specific language governing permissions and
* limitations under the License.
*/

var fs = require('fs');

var red   = '\033[31m';
var green   = '\033[32m';
var blue   = '\033[34m';
var yellow   = '\033[33m';
var reset = '\033[0m';

function logErr (message) {
    console.log(red + "error:  " + message + reset);
}

function logStatus (message) {
    console.log(yellow + "info:   " + message + reset);
}

function logStatus2 (message) {
    console.log(blue + "info:   " + message + reset);
}

// ************* Progress display **********************************************************************
var progressChars = ['-', '\\', '|', '/'];
var progressIndex = 0;
var activeProgressTimer;

function drawAndUpdateProgress() {
    fs.writeSync(2, '\r');
    process.stderr.write(progressChars[progressIndex]);

    progressIndex = progressIndex + 1;
    if (progressIndex == progressChars.length) {
      progressIndex = 0;
    }
}

function clearProgress() {
    fs.writeSync(2, '\r');
    fs.writeSync(2, clearBuffer);
    fs.writeSync(2, '\r');
}

progress = function(label) {

    // Clear the console
    fs.writeSync(2, '\r');
    fs.writeSync(2, clearBuffer);
    
    // Draw initial progress
    drawAndUpdateProgress();
    
    // Draw label
    if (label) {
        fs.writeSync(2, ' ' + label);
    }
    
    activeProgressTimer = setInterval(function() {
        drawAndUpdateProgress();
    }, 200);

    return {
        end: function() {
            clearInterval(activeProgressTimer);
            activeProgressTimer = null;
            
            clearProgress();
        }
    };
};

var clearBuffer = new Buffer(79, 'utf8');
clearBuffer.fill(' ');
clearBuffer = clearBuffer.toString();

// **************************** Exit *******************************************************************
exitWithError = function(message) {
    // Stop progress
    if (activeProgressTimer) {
        clearInterval(activeProgressTimer);
    }

    logErr(message);
    process.exit(1);
};

// *************************** Usage *******************************************************************

showUsageAndExit = function(message) {
    var usage = 'node.exe check-status.js lib:<path-to-lib> pem:<pem-path> s:<subscription-id> dnsprefix:<dns-prefix-name> user:<user-name> password:<password> remoteport:<remote-port> mongoports:<mongo-ports> replica:<replica-name> host:<service-host>';
    // Stop progress
    if (activeProgressTimer) {
        clearInterval(activeProgressTimer);
    }

    console.log( yellow + "USAGE:  " + usage + reset);
    process.exit(1);
};

// **************************** Command-Line Args Processing *******************************************

var input = {
  lib: { 'name': 'path-to-lib', 'value': null, 'found': false },
  pem: { 'name': 'pem-path', 'value': null, 'found': false },
  s: { 'name': 'subscription-id', 'value': null, 'found': false },
  dnsprefix: { 'name': 'dnsprefix', 'value': null, 'found': false },
  user: { 'name': 'user', 'value': null, 'found': false },
  password: { 'name': 'password', 'value': null, 'found': false },
  remoteport: { 'name': 'remoteport', 'value': null, 'found': false },
  mongoports: { 'name': 'mongoports', 'value': null, 'found': false },
  replica: { 'name': 'replica', 'value': null, 'found': false },
  host: { 'name': 'host', 'value': null, 'found': false }
};

var args = getCommandLineArgs();
if (args.length != 10) {
  showUsageAndExit();
}

for (var i = 0; i < args.length; i++) {
  var k = args[i].key;
  if (typeof input[k] == "undefined") {
    logErr('Unknown option ' + k);
    showUsageAndExit();
  }

  if (input[k].found) {
    logErr('found repeated-option ' + k);
    showUsageAndExit();
  } else {
    input[k].value = args[i].value;
    input[k].found = true;
  }
}

function getCommandLineArgs() {
  var args = [];
  process.argv.forEach(function (val, index, array) {
    if (index != 0 && index != 1) {
      var parts = val.split('=', 2);
      if (parts.length != 2) {
        showUsageAndExit();
      }

      var keyValue = {
        key: parts[0],
        value: parts[1]
      }

      if (keyValue.key == '' || keyValue.value == '') {
        showUsageAndExit();
      }

      args.push(keyValue);
    }
  });

  return args;
}

//***************************** Get the certificates ***************************************************

var KEY_PATT = /(-+BEGIN RSA PRIVATE KEY-+)(\n\r?|\r\n?)([A-Za-z0-9\+\/\n\r]+\=*)(\n\r?|\r\n?)(-+END RSA PRIVATE KEY-+)/;
var CERT_PATT = /(-+BEGIN CERTIFICATE-+)(\n\r?|\r\n?)([A-Za-z0-9\+\/\n\r]+\=*)(\n\r?|\r\n?)(-+END CERTIFICATE-+)/;

var keyCert = readFromFile(input['pem'].value);
var param = {
  subscriptionId : input['s'].value,
  auth : { keyvalue : keyCert.key, certvalue : keyCert.cert}
};

function readFromFile(fileName) {
  // other parameters are optional
  var data = fs.readFileSync(fileName, 'utf8');
  var ret = {};
  var matchKey = data.match(KEY_PATT);
  if (matchKey) {
    ret.key = matchKey[1] + '\n' + matchKey[3] + '\n' + matchKey[5] + '\n';
  } 
  var matchCert = data.match(CERT_PATT);
  if (matchCert) {
    ret.cert = matchCert[1] + '\n' + matchCert[3] + '\n' + matchCert[5] + '\n';
  }
  return ret;
};

//***************************** Check for Status *******************************************************
var azure = require(input['lib'].value + '/azure');

param["host"] = input['host'].value

var CONFIG_FILE_LOC = __dirname + '/config.json'
var CONN_STR_FILE_LOC_PREFIX = __dirname + '/connectionStrings'

var managementService = tryGetMgmtServiceInstance(param);

checkStatus(managementService, input['dnsprefix'].value, function(error, result, status) {
  if (status) {
    console.log('\033[36m' + result + reset);
    logStatus("Preparing the configuration file");
    var config = [];
    var connectionStrings = []
    config.push({"SSH": [{ "info":  { "host": null, "user": null, "password": null, "ports": [] } } ] });
    config.push({"VMS": [{ "info":  { "ips": [] } } ] });
    config.push({"DNS": [{ "info":  { "name": input['dnsprefix'].value } } ] });
    connectionStrings.push({"Credentials": [{ "info":  { "user": null, "password": null} } ] });
    connectionStrings.push({"RDP": [{ "info":  { "connectionUrl": [] } } ] });
    connectionStrings.push({"Mongo": [{ "info":  { "connectionUrl": [] } } ] });
    connectionStrings.push({"Remoting": [{ "info":  { "connectionUrl": [] } } ] });
    managementService.getDeployment(input['dnsprefix'].value, input['dnsprefix'].value, function (error, rspobj) {
      if (rspobj.isSuccessful && rspobj.body) {
        config[0].SSH[0].info.host = rspobj.body.Url[rspobj.body.Url.length - 1] === "/" ? 
          rspobj.body.Url.substring(0, rspobj.body.Url.length - 1) : rspobj.body.Url;
        if (config[0].SSH[0].info.host.indexOf("http://") === 0) {
          config[0].SSH[0].info.host = config[0].SSH[0].info.host.substring(7);
        }

        connectionStrings[0].Credentials[0].info.user = config[0].SSH[0].info.user = input['user'].value;
        connectionStrings[0].Credentials[0].info.password = '******';
        var replicaSetUrl = "mongodb://";
        var sshPorts = [];
        
        var roleList = rspobj.body.RoleInstanceList;
        var hasReplica = roleList.length === 1 ? false : true;
        for(var i = 0; i < roleList.length; i++) {
          var comma = (i !== roleList.length - 1) ? "," : "";
          var endPoints = roleList[i].InstanceEndpoints;
          var foundMongoEndPoint = false
          for(j=0; j < endPoints.length; j++) {
            var endPoint = endPoints[j];
            if (parseInt(endPoint.LocalPort, 10) === parseInt(input['remoteport'].value, 10)) {
                config[0].SSH[0].info.ports.push(endPoint.PublicPort);
                config[1].VMS[0].info.ips.push(roleList[i].IpAddress);
                connectionStrings[3].Remoting[0].info.connectionUrl.push(config[0].SSH[0].info.host + ":" + endPoint.PublicPort);
            } else if (parseInt(endPoint.LocalPort, 10) === 3389) {
                connectionStrings[1].RDP[0].info.connectionUrl.push(config[0].SSH[0].info.host + ":" + endPoint.PublicPort);
            } else {
                var localPort = endPoint.LocalPort
                localPort = localPort.toString()
                if (input['mongoports'].value.indexOf(localPort) !== -1) {
                    var mongoUrl = config[0].SSH[0].info.host + ":" + endPoint.PublicPort;
                    connectionStrings[2].Mongo[0].info.connectionUrl.push(mongoUrl);
                    replicaSetUrl = replicaSetUrl + mongoUrl + comma
                    foundMongoEndPoint = true
                }
            }
          }

          if (!foundMongoEndPoint) {
            exitWithError("Found a VM without a endpoint in the mongoport list " + input['mongoports'].value + " Make sure endpoint for mongo is defined and both external and internal port has same value");
          }
        }

        if(config[0].SSH[0].info.ports.length !== roleList.length) {
          exitWithError("Found VM(s) without Remoting port " + input['remoteport'].value + " endpoint defined");
        }
        
        if (hasReplica) {
            connectionStrings[2].Mongo[0].info["ReplicaSetUrl"] = replicaSetUrl + "?replicaSet=" + input['replica'].value;
            connectionStrings[2].Mongo[0].info["ReplicaSetName"] = input['replica'].value;
        }

        var str = JSON.stringify(config);
        fs.writeFile(CONFIG_FILE_LOC, str, function(err) {
          if(err) {
            exitWithError(err);
          } else {
            logStatus("Saved the configuration file");
          }
        });
        
        str = JSON.stringify(connectionStrings);
        fs.writeFile((CONN_STR_FILE_LOC_PREFIX + '-' + input['dnsprefix'].value + '.json'), str, function(err) {
          if(err) {
            exitWithError(err);
          } else {
            logStatus("Saved the connection-strings file");
          }
        });
      }
    });
  } else {
    exitWithError(error);
  }
});

function checkStatus(managementService, hostedServDeplName, callback) {
  var k = 0;
  var provisioningFailed = false;
  var prevRoles = [];
  var prg = progress('Checking Status of Roles')
    var timerfun = function (managementService, hostedServDeplName, callback) {
    k++;
    getRoles(managementService, hostedServDeplName, function (error, roles) {
      if(error) {
        prg.end();
        callback(error, 'ERROR', false);
      } else {
        var allready = true;
        var result = '';
        for (var i = 0; i < roles.length; i++) {
          if (roles[i].Status !== 'ReadyRole') {
            allready = false;
          }

          if (roles[i].Status === 'ProvisioningFailed') {
            provisioningFailed = true;
          }

          result += roles[i].Name + ':' + roles[i].Status + ' ' ;
        }

        if (provisioningFailed) {
          prg.end();
          exitWithError(result);
        }

        if (allready) {
          if (prevRoles.length !== roles.length) {
            allready = false;
          } else {
            for (var m = 0; m < roles.length; m++) {
              for(var p = 0; p < roles.length; p++) {
                if (roles[m].Name === prevRoles[p].Name) {
                  if (prevRoles[p].Status !== 'BusyRole' && prevRoles[p].Status !== 'ReadyRole') {
                    allready = false;
                    break;
                  }
                }
              }
            }
          }
        }

        prevRoles = [];
        // Backup the current role details
        for (var n = 0; n < roles.length; n++) {
          prevRoles.push({Name: roles[n].Name, Status: roles[n].Status});
        }

        if (allready) {
          prg.end();
          callback(null, result, true);
        } else {
          prg.end();
          if (result.length > 73) {
            result = result.substring(0, 73);
            result = result + '..';
          }

          prg = progress(result);
          setTimeout(function () { timerfun(managementService, hostedServDeplName, callback) }, 6000);
        }
      }
    });
  }

  timerfun(managementService, hostedServDeplName, callback);
}

function getRoles(managementService, hostedServDeplName, callback) {
  managementService.getDeployment(hostedServDeplName, hostedServDeplName, function (error, rspobj) {
    var roles = [];
    if(!error) {
      var roleList = rspobj.body.RoleInstanceList;
      for (var i = 0; i < roleList.length; i++) {
        roles.push({'Name' : roleList[i].RoleName, 'Status' : roleList[i].InstanceStatus});
      }

      callback(null, roles);
    } else {
      callback(error, roles);
    }
  });
}

function tryGetMgmtServiceInstance(param)
{
  var managementService = null;
  try {
    managementService = azure.createServiceManagementService(
      param.subscriptionId,
      param.auth,
      {
          host: param.host
      }
    );
  } catch (error) {
    exitWithError('Failed to create ServiceManagementService instance -- ' + error);
  }

  return managementService;
}
