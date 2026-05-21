import argparse
import asyncio
import bruteratel

async def main():
    parser = argparse.ArgumentParser(
        description="Hosts a local file on a given listener with a mimetype and new uri",
        epilog="Example:\n python3 api_host_file.py -user ninja -password pass@123 -handler 172.16.219.1:8443 -uri test.json -file abcd.json -mimetype 'application/json' -listener primary-c2",
        formatter_class=argparse.RawTextHelpFormatter
    )
    parser.add_argument('-user',     type=str, required=True, help="api server username", metavar='')
    parser.add_argument('-password', type=str, required=True, help="api server password", metavar='')
    parser.add_argument('-handler',  type=str, required=True, help="api server handler host and port. Eg: 127.0.0.1:8443", metavar='')
    parser.add_argument('-listener', type=str, required=True, help="listener name to modify", metavar='')
    parser.add_argument('-uri',      type=str, required=True, help="listener uri to add", metavar='')
    parser.add_argument('-mimetype', type=str, required=True, help="mime type of file", metavar='')
    parser.add_argument('-file',     type=str, required=True, help="file path to read", metavar='')
    args = parser.parse_args()

    wsClient = await bruteratel.br_connect_handler(args.user, args.password, args.handler)
    print("[+] Authentication success")

    if (await bruteratel.br_host_file(wsClient, args.listener, args.uri, args.mimetype, args.file)):
        print("[+] File hosted")
    else:
        print("[-] Error hosting file")

    await wsClient.close(1000)

if __name__ == "__main__":
    asyncio.run(main())
