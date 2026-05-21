import argparse
import asyncio
import bruteratel

async def main():
    parser = argparse.ArgumentParser(
        description="Create a http, dns or doh listener using a local listener profile",
        epilog="" \
        "Example:\n" \
        " python3 api_add_listener.py -user ninja -password pass@123 -handler 172.16.219.1:8443 -type http -config conf/http.json\n" \
        " python3 api_add_listener.py -user ninja -password pass@123 -handler 172.16.219.1:8443 -type dns -config conf/dns.json",
        formatter_class=argparse.RawTextHelpFormatter
    )
    parser.add_argument('-user',     type=str, required=True, help="api server username", metavar='')
    parser.add_argument('-password', type=str, required=True, help="api server password", metavar='')
    parser.add_argument('-handler',  type=str, required=True, help="api server handler host and port. Eg: 127.0.0.1:8443", metavar='')
    parser.add_argument('-type',     type=str, required=True, help="listener type. Eg.: http/dns", metavar='')
    parser.add_argument('-config',   type=str, required=True, help="dns/doh/http listener config file path", metavar='')
    args = parser.parse_args()

    wsClient = await bruteratel.br_connect_handler(args.user, args.password, args.handler)
    print("[+] Authentication success")

    if (await bruteratel.br_add_listener(wsClient, args.config, args.type)):
        print("[+] Listener created")
    else:
        print("[-] Error creating listener")

    await wsClient.close(1000)

if __name__ == "__main__":
    asyncio.run(main())
