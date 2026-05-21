import argparse
import asyncio
import bruteratel

async def main():
    parser = argparse.ArgumentParser(
        description="Removes a hosted file from a listener",
        epilog="Example:\n python3 api_remove_hosted_file.py -user ninja -password pass@123 -handler 172.16.219.1:8443 -uri 'primary-c2/test.php'",
        formatter_class=argparse.RawTextHelpFormatter
    )
    parser.add_argument('-user',     type=str, required=True, help="api server username", metavar='')
    parser.add_argument('-password', type=str, required=True, help="api server password", metavar='')
    parser.add_argument('-handler',  type=str, required=True, help="api server handler host and port. Eg: 127.0.0.1:8443", metavar='')
    parser.add_argument('-uri',      type=str, required=True, help="hosted uri (listener_name/uri format) to remove", metavar='')
    args = parser.parse_args()

    wsClient = await bruteratel.br_connect_handler(args.user, args.password, args.handler)
    print("[+] Authentication success")

    if (await bruteratel.br_stop_hosting(wsClient, args.uri)):
        print("[+] Removed hosted file")
    else:
        print("[-] Error removing hosted file")

    await wsClient.close(1000)

if __name__ == "__main__":
    asyncio.run(main())
