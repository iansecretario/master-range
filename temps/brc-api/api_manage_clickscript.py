import argparse
import asyncio
import bruteratel
import sys
# import json

async def main():
    parser = argparse.ArgumentParser(
        description="List or add a clickscript to the ratel server",
        epilog="Example:\n" \
        " python3 api_manage_clickscript.py -user ninja -password pass@123 -handler 172.16.219.1:8443 -list\n" \
        " python3 api_manage_clickscript.py -user ninja -password pass@123 -handler 172.16.219.1:8443 -add profiles/clickscripts.json",
        formatter_class=argparse.RawTextHelpFormatter
    )
    parser.add_argument('-user',       type=str,            required=True,  help="api server username", metavar='')
    parser.add_argument('-password',   type=str,            required=True,  help="api server password", metavar='')
    parser.add_argument('-handler',    type=str,            required=True,  help="api server handler host and port. Eg: 127.0.0.1:8443", metavar='')
    parser.add_argument('-list',       action='store_true', required=False, help="list clickscripts")
    parser.add_argument('-add',        type=str,            required=False, help="add clickscripts using a clickscript file path. clickscripts can be removed using an empty clickscript json file", metavar='')
    args = parser.parse_args()

    if not args.list and not args.add and not args.remove:
        parser.print_usage()
        sys.exit(0)

    wsClient = await bruteratel.br_connect_handler(args.user, args.password, args.handler)
    print("[+] Authentication success")

    taskType = ""
    argData = None
    if args.list:
        taskType = "list"
        argData = None
    elif args.add:
        taskType = "add"
        argData = args.add

    clickscript_list = await bruteratel.br_manage_clickscript(wsClient, argData, taskType)
    if clickscript_list is not None:
        if taskType == "list":
            print("[+] Clickscript list:")
            for scriptName, scriptList in clickscript_list.items():
                print("  -", scriptName)
                for cmd in scriptList:
                    print("    -", cmd)
        elif taskType == "add" and clickscript_list is True:
            print("[+] Replaced existing clickscript")
    else:
        print("[-] Error listing clickscripts")

    await wsClient.close(1000)

if __name__ == "__main__":
    asyncio.run(main())
