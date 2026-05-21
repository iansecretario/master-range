import argparse
import asyncio
import bruteratel

async def main():
    parser = argparse.ArgumentParser(
        description="Queues a command to a listener to send it to all badgers",
        epilog="Example:\n python3 api_riot_control.py -user ninja -password pass@123 -handler 172.16.219.1:8443 -listener primary-c2 -cmd 'ls C:\'",
        formatter_class=argparse.RawTextHelpFormatter
    )
    parser.add_argument('-user',     type=str, required=True, help="api server username", metavar='')
    parser.add_argument('-password', type=str, required=True, help="api server password", metavar='')
    parser.add_argument('-handler',  type=str, required=True, help="api server handler host and port. Eg: 127.0.0.1:8443", metavar='')
    parser.add_argument('-listener', type=str, required=True, help="listener name to run badger's command", metavar='')
    parser.add_argument('-cmd',      type=str, required=True, help="command to send to all badgers on the listener", metavar='')
    args = parser.parse_args()

    wsClient = await bruteratel.br_connect_handler(args.user, args.password, args.handler)
    print("[+] Authentication success")

    cmd_sent_count = await bruteratel.br_riot_control(wsClient, args.listener, args.cmd)
    if cmd_sent_count is not None:
        print(f"[+] Sent '{args.cmd}' to {cmd_sent_count} badgers")
    else:
        print("[-] Error sending command")
    await wsClient.close(1000)

if __name__ == "__main__":
    asyncio.run(main())
