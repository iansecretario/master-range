import argparse
import asyncio
import json
import bruteratel

async def main():
    parser = argparse.ArgumentParser(
        description="List connected badgers and their metadata (-dump)",
        epilog="Example:\n" \
        " python3 api_list_badgers.py -user ninja -password pass@123 -handler 172.16.219.1:8443\n" \
        " python3 api_list_badgers.py -user ninja -password pass@123 -handler 172.16.219.1:8443 -dump",
        formatter_class=argparse.RawTextHelpFormatter
    )
    parser.add_argument('-user',     type=str,            required=True,  help="api server username", metavar='')
    parser.add_argument('-password', type=str,            required=True,  help="api server password", metavar='')
    parser.add_argument('-handler',  type=str,            required=True,  help="api server handler host and port. Eg: 127.0.0.1:8443", metavar='')
    parser.add_argument('-dump',     action='store_true', required=False, help="list in brief")
    args = parser.parse_args()

    wsClient = await bruteratel.br_connect_handler(args.user, args.password, args.handler)
    print("[+] Authentication success")

    bgr_info = await bruteratel.br_list_badgers(wsClient)
    if bgr_info is not None:
        print("[+] Badger info:")
        if args.dump:
            print(json.dumps(bgr_info, indent=4))
        else:
            for bgrId, _ in bgr_info.items():
                print("  - ", bgrId)
    else:
        print("[-] Error sending command")

    await wsClient.close(1000)

if __name__ == "__main__":
    asyncio.run(main())
