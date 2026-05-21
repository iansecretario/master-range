import argparse
import asyncio
import sys
import bruteratel

async def main():
    parser = argparse.ArgumentParser(
        description="List, add or remove harvested credentials from the server",
        epilog="Example:\n" \
        " python3 api_manage_creds.py -user ninja -password pass@123 -handler 172.16.219.1:8443 -list\n" \
        " python3 api_manage_creds.py -user ninja -password pass@123 -handler 172.16.219.1:8443 -add -creddomain ratel.corp -crednote 'Domain Admin Password' -credpass admin@123 -creduser administrator\n" \
        " python3 api_manage_creds.py -user ninja -password pass@123 -handler 172.16.219.1:8443 -remove -creddomain ratel.corp -crednote 'Domain Admin Password' -credpass admin@123 -creduser administrator",
        formatter_class=argparse.RawTextHelpFormatter
    )
    parser.add_argument('-user',       type=str,            required=True,  help="api server username", metavar='')
    parser.add_argument('-password',   type=str,            required=True,  help="api server password", metavar='')
    parser.add_argument('-handler',    type=str,            required=True,  help="api server handler host and port. Eg: 127.0.0.1:8443", metavar='')
    parser.add_argument('-creddomain', type=str,            required=False, help="domain name for credential", metavar='')
    parser.add_argument('-crednote',   type=str,            required=False, help="note for credential", metavar='')
    parser.add_argument('-creduser',   type=str,            required=False, help="username for credential", metavar='')
    parser.add_argument('-credpass',   type=str,            required=False, help="password for credential", metavar='')
    parser.add_argument('-add',        action='store_true', required=False, help="add this credential data")
    parser.add_argument('-remove',     action='store_true', required=False, help="remove credential data which matches this list")
    parser.add_argument('-list',       action='store_true', required=False, help="list available credential data")
    args = parser.parse_args()

    if not args.add and not args.remove and not args.list:
        parser.print_help()
        sys.exit(0)

    if args.add or args.remove:
        if not args.creddomain or not args.crednote or not args.creduser or not args.credpass:
            parser.print_usage()
            sys.exit(0)

    wsClient = await bruteratel.br_connect_handler(args.user, args.password, args.handler)
    print("[+] Authentication success")

    doAdd = False
    if args.add:
        doAdd = True

    if args.add or args.remove:
        if (await bruteratel.br_manage_creds(wsClient, args.creddomain, args.creduser, args.credpass, args.crednote, doAdd)):
            if doAdd:
                print("[+] Added credentials")
            else:
                print("[+] Removed credentials")
        else:
            if doAdd:
                print("[-] Error adding credentials")
            else:
                print("[-] Error removing credentials")
    elif args.list:
        credlist = await bruteratel.br_list_creds(wsClient)
        if credlist is not None:
            print("[+] Credentials:")
            for clist in credlist:
                for x, y in clist.items():
                    print("  - " + x + " :" + y)
                print()
        else:
            print("[-] Error listing credentials")
    else:
        parser.print_help()

    await wsClient.close(1000)

if __name__ == "__main__":
    asyncio.run(main())
