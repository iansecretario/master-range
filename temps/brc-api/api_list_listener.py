import argparse
import asyncio
import bruteratel

async def main():
    parser = argparse.ArgumentParser(
        description="List available listeners on the ratel server",
        epilog="Example:\n python3 api_list_listener.py -user ninja -password pass@123 -handler 172.16.219.1:8443",
        formatter_class=argparse.RawTextHelpFormatter
    )
    parser.add_argument('-user',     type=str, required=True, help="api server username", metavar='')
    parser.add_argument('-password', type=str, required=True, help="api server password", metavar='')
    parser.add_argument('-handler',  type=str, required=True, help="api server handler host and port. Eg: 127.0.0.1:8443", metavar='')
    args = parser.parse_args()

    wsClient = await bruteratel.br_connect_handler(args.user, args.password, args.handler)
    print("[+] Authentication success")

    listenerlist = await bruteratel.br_list_listeners(wsClient)
    if listenerlist is not None:
        print("[+] listeners:")
        for i in listenerlist:
            print("  - ", i)
    else:
        print("[-] Error listing listeners")

    await wsClient.close(1000)

if __name__ == "__main__":
    asyncio.run(main())

