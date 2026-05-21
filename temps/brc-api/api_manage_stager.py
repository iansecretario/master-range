import argparse
import asyncio
import bruteratel

async def main():
    parser = argparse.ArgumentParser(
        description="Enable or disable a stager on a listener. Setting the count to zero disables a stager. If staging is being enabled, stage count cannot be zero. Staging status can be seen in listener config dump",
        epilog="Example:\n python3 api_manage_stager.py -user ninja -password pass@123 -handler 172.16.219.1:8443 -listener primary-c2 -profile doh-c2 -count 10",
        formatter_class=argparse.RawTextHelpFormatter
    )
    parser.add_argument('-user',     type=str, required=True,  help="api server username", metavar='')
    parser.add_argument('-password', type=str, required=True,  help="api server password", metavar='')
    parser.add_argument('-handler',  type=str, required=True,  help="api server handler host and port. Eg: 127.0.0.1:8443", metavar='')
    parser.add_argument('-listener', type=str, required=True,  help="listener name to enable staging on", metavar='')
    parser.add_argument('-profile',  type=str, required=False, help="enable staging for the listener with a profile name. if staging is being enabled, stage count cannot be zero", metavar='')
    parser.add_argument('-count',    type=int, required=True,  help="count of stages. set this to zero to disable staging", metavar=0)
    args = parser.parse_args()

    wsClient = await bruteratel.br_connect_handler(args.user, args.password, args.handler)
    print("[+] Authentication success")

    if args.count == 0:
        if (await bruteratel.br_set_stage(wsClient, args.listener, None, 0)):
            print("[+] Stager disabled")
        else:
            print("[-] Error disabling stager")

    elif args.count > 0 and args.profile:
        if (await bruteratel.br_set_stage(wsClient, args.listener, args.profile, args.count)):
            print("[+] Stager enabled")
        else:
            print("[-] Error enabling stager")
    else:
        parser.print_help()

    await wsClient.close(1000)

if __name__ == "__main__":
    asyncio.run(main())
