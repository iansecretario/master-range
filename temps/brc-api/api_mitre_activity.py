import argparse
import asyncio
import json
import bruteratel

async def main():
    parser = argparse.ArgumentParser(
        description="List MITRE activity of badgers",
        epilog="Example:\n python3 api_mitre_activity.py -user ninja -password pass@123 -handler 172.16.219.1:8443",
        formatter_class=argparse.RawTextHelpFormatter
    )
    parser.add_argument('-user',     type=str, required=True, help="api server username", metavar='')
    parser.add_argument('-password', type=str, required=True, help="api server password", metavar='')
    parser.add_argument('-handler',  type=str, required=True, help="api server handler host and port. Eg: 127.0.0.1:8443", metavar='')
    args = parser.parse_args()

    wsClient = await bruteratel.br_connect_handler(args.user, args.password, args.handler)
    print("[+] Authentication success")

    user_activity = await bruteratel.br_list_mitre_activity(wsClient)
    if user_activity is not None:
        print("[+] MITRE activity:\n", json.dumps(user_activity, indent=4))
    else:
        print("[-] Error listing MITRE activity")
    await wsClient.close(1000)

if __name__ == "__main__":
    asyncio.run(main())
