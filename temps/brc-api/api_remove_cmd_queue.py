import argparse
import asyncio
import bruteratel

async def main():
    parser = argparse.ArgumentParser(
        description="Clears a badger's command queue",
        epilog="Example:\n python3 api_remove_cmd_queue.py -user ninja -password pass@123 -handler 172.16.219.1:8443 -badger b-1",
        formatter_class=argparse.RawTextHelpFormatter
    )
    parser.add_argument('-user',     type=str, required=True, help="api server username", metavar='')
    parser.add_argument('-password', type=str, required=True, help="api server password", metavar='')
    parser.add_argument('-handler',  type=str, required=True, help="api server handler host and port. Eg: 127.0.0.1:8443", metavar='')
    parser.add_argument('-badger',   type=str, required=True, help="badger id to clear command queue", metavar='')
    args = parser.parse_args()

    wsClient = await bruteratel.br_connect_handler(args.user, args.password, args.handler)
    print("[+] Authentication success")

    if (await bruteratel.br_clear_cmd_q(wsClient, args.badger)):
        print("[+] Cleared cmd queue")
    else:
        print("[-] Error clearing cmd queue")

    await wsClient.close(1000)

if __name__ == "__main__":
    asyncio.run(main())
