import argparse
import asyncio
import bruteratel

async def main():
    parser = argparse.ArgumentParser(
        description="List hosted files on a listener",
        epilog="Example:\n python3 api_list_hosted.py -user ninja -password pass@123 -handler 172.16.219.1:8443",
        formatter_class=argparse.RawTextHelpFormatter
    )
    parser.add_argument('-user',     type=str, required=True, help="api server username", metavar='')
    parser.add_argument('-password', type=str, required=True, help="api server password", metavar='')
    parser.add_argument('-handler',  type=str, required=True, help="api server handler host and port. Eg: 127.0.0.1:8443", metavar='')
    args = parser.parse_args()

    wsClient = await bruteratel.br_connect_handler(args.user, args.password, args.handler)
    print("[+] Authentication success")

    hostedInfo = await bruteratel.br_list_hosted(wsClient)
    if hostedInfo is not None:
        print("[+] Hosted files:")
        for c2uri, mimetype in hostedInfo.items():
            print(f"  - {c2uri} => {mimetype}")
    else:
        print("[-] Error hosting file")

    await wsClient.close(1000)

if __name__ == "__main__":
    asyncio.run(main())
