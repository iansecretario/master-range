import argparse
import asyncio
import bruteratel

async def main():
    parser = argparse.ArgumentParser(
        description="Remove a badger profile from the ratel server",
        epilog="Example:\n python3 api_remove_badger_profile.py -user ninja -password pass@123 -handler 172.16.219.1:8443 -profile my-tcp",
        formatter_class=argparse.RawTextHelpFormatter
    )
    parser.add_argument('-user',     type=str, required=True, help="api server username", metavar='')
    parser.add_argument('-password', type=str, required=True, help="api server password", metavar='')
    parser.add_argument('-handler',  type=str, required=True, help="api server handler host and port. Eg: 127.0.0.1:8443", metavar='')
    parser.add_argument('-profile',  type=str, required=True, help="badger profile name", metavar='')
    args = parser.parse_args()

    wsClient = await bruteratel.br_connect_handler(args.user, args.password, args.handler)
    print("[+] Authentication success")

    if (await bruteratel.br_delete_badger_profile(wsClient, args.profile)):
        print("[+] Profile deleted")
    else:
        print("[-] Error deleting profile")

    await wsClient.close(1000)

if __name__ == "__main__":
    asyncio.run(main())
