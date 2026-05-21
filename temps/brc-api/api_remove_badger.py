import argparse
import asyncio
import bruteratel

async def main():
    parser = argparse.ArgumentParser(
        description="Removes a badger from the user interface and its metadata from the server",
        epilog="Example:\n python3 api_remove_badger.py -user ninja -password pass@123 -handler 172.16.219.1:8443 -badgerlist b-0,b-1,b-2",
        formatter_class=argparse.RawTextHelpFormatter
    )
    parser.add_argument('-user',       type=str, required=True, help="api server username", metavar='')
    parser.add_argument('-password',   type=str, required=True, help="api server password", metavar='')
    parser.add_argument('-handler',    type=str, required=True, help="api server handler host and port. Eg: 127.0.0.1:8443", metavar='')
    parser.add_argument('-badgerlist', type=str, required=True, help="comma seperated badger list (without space) to remove the badger from server and UI", metavar='')
    args = parser.parse_args()

    wsClient = await bruteratel.br_connect_handler(args.user, args.password, args.handler)
    print("[+] Authentication success")

    if (await bruteratel.br_remove_badgers(wsClient, args.badgerlist)):
        print("[+] Badger removed")
    else:
        print("[-] Error removing badger")

    await wsClient.close(1000)

if __name__ == "__main__":
    asyncio.run(main())
