import argparse
import asyncio
import bruteratel
import json

async def main():
    parser = argparse.ArgumentParser(
        description="Dump server configuration in json which can be used to restore a terminated/crashed server",
        epilog="Example:\n python3 api_server_backup.py -user ninja -password pass@123 -handler 172.16.219.1:8443",
        formatter_class=argparse.RawTextHelpFormatter
    )
    parser.add_argument('-user',     type=str, required=True, help="api server username", metavar='')
    parser.add_argument('-password', type=str, required=True, help="api server password", metavar='')
    parser.add_argument('-handler',  type=str, required=True, help="api server handler host and port. Eg: 127.0.0.1:8443", metavar='')
    args = parser.parse_args()

    wsClient = await bruteratel.br_connect_handler(args.user, args.password, args.handler)
    print("[+] Authentication success")

    server_conf = await bruteratel.br_server_backup(wsClient)
    if server_conf is not None:
        print("[+] Server backup config:\n", json.dumps(server_conf, indent=4))
    else:
        print("[-] Error creating listener")

    await wsClient.close(1000)

if __name__ == "__main__":
    asyncio.run(main())
