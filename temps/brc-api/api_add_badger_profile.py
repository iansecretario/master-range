import argparse
import asyncio
import bruteratel

async def main():
    parser = argparse.ArgumentParser(
        description="Adds a tcp/smb/http/doh/dns badger profile for payload generation",
        epilog="Example:\n python3 api_add_badger_profile.py -user ninja -password pass@123 -handler 172.16.219.1:8443 -config conf/profile_smb.json",
        formatter_class=argparse.RawTextHelpFormatter
    )
    parser.add_argument('-user',     type=str, required=True, help="api server username", metavar='')
    parser.add_argument('-password', type=str, required=True, help="api server password", metavar='')
    parser.add_argument('-handler',  type=str, required=True, help="api server handler host and port. Eg: 127.0.0.1:8443", metavar='')
    parser.add_argument('-config',   type=str, required=True, help="badger config file path", metavar='')
    args = parser.parse_args()

    wsClient = await bruteratel.br_connect_handler(args.user, args.password, args.handler)
    print("[+] Authentication success")

    if (await bruteratel.br_add_badger_profile(wsClient, args.config)):
        print("[+] Profile added")
    else:
        print("[-] Error adding profile")

    await wsClient.close(1000)

if __name__ == "__main__":
    asyncio.run(main())
