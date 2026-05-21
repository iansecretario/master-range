import argparse
import asyncio
import bruteratel

async def main():
    parser = argparse.ArgumentParser(
        description="Sends command to a badger using badger ID",
        epilog="Example:\n python3 api_send_badger_cmd.py -user ninja -password pass@123 -handler 172.16.219.1:8443 -badger b-2 -cmd 'ls C:\'",
        formatter_class=argparse.RawTextHelpFormatter
    )
    parser.add_argument('-user',     type=str, required=True, help="api server username", metavar='')
    parser.add_argument('-password', type=str, required=True, help="api server password", metavar='')
    parser.add_argument('-handler',  type=str, required=True, help="api server handler host and port. Eg: 127.0.0.1:8443", metavar='')
    parser.add_argument('-badger',   type=str, required=True, help="badger id", metavar='')
    parser.add_argument('-cmd',      type=str, required=True, help="command to send", metavar='')
    args = parser.parse_args()

    wsClient = await bruteratel.br_connect_handler(args.user, args.password, args.handler)
    print("[+] Authentication success")

    if (await bruteratel.br_set_bgr_cmd(wsClient, args.badger, args.cmd)):
        print("[+] Command sent")
    else:
        print("[-] Error sending command")

    await wsClient.close(1000)

if __name__ == "__main__":
    asyncio.run(main())
