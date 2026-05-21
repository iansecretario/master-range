import argparse
import asyncio
import bruteratel
import sys
# import json

async def main():
    parser = argparse.ArgumentParser(
        description="Add, list or remove autoruns from the server in FIFO format",
        epilog="Example:\n" \
        " python3 api_manage_autoruns.py -user ninja -password pass@123 -handler 172.16.219.1:8443 -list\n" \
        " python3 api_manage_autoruns.py -user ninja -password pass@123 -handler 172.16.219.1:8443 -add 'pwd'\n" \
        " python3 api_manage_autoruns.py -user ninja -password pass@123 -handler 172.16.219.1:8443 -remove 'pwd'",
        formatter_class=argparse.RawTextHelpFormatter
    )
    parser.add_argument('-user',     type=str,            required=True,  help="api server username", metavar='')
    parser.add_argument('-password', type=str,            required=True,  help="api server password", metavar='')
    parser.add_argument('-handler',  type=str,            required=True,  help="api server handler host and port. Eg: 127.0.0.1:8443", metavar='')
    parser.add_argument('-list',     action='store_true', required=False, help="list autoruns")
    parser.add_argument('-add',      type=str,            required=False, help="add autoruns", metavar='')
    parser.add_argument('-remove',   type=str,            required=False, help="remove autoruns", metavar='')
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
    elif args.remove:
        taskType = "remove"
        argData = args.remove

    autorun_list = await bruteratel.br_manage_autoruns(wsClient, argData, taskType)
    if autorun_list is not None:
        print("[+] Autorun list:")
        for cmd in autorun_list:
            print("  -", cmd)
    else:
        print("[-] Error listing autoruns")

    await wsClient.close(1000)

if __name__ == "__main__":
    asyncio.run(main())
