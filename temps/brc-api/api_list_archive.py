import argparse
import asyncio
import bruteratel

async def main():
    parser = argparse.ArgumentParser(
        description="Lists data in archive such as badger logs, server logs, screenshots and downloads",
        epilog="Example:\n" \
        " python3 api_list_archive.py -user ninja -password pass@123 -handler 172.16.219.1:8443 -list logs\n" \
        " python3 api_list_archive.py -user ninja -password pass@123 -handler 172.16.219.1:8443 -list downloads",
        formatter_class=argparse.RawTextHelpFormatter
    )
    parser.add_argument('-user',    type=str, required=True, help="api server username", metavar='')
    parser.add_argument('-password',type=str, required=True, help="api server password", metavar='')
    parser.add_argument('-handler', type=str, required=True, help="api server handler host and port. Eg: 127.0.0.1:8443", metavar='')
    parser.add_argument('-list',    type=str, required=True, help="list 'logs' or 'downloads' from the server", metavar='')
    args = parser.parse_args()

    wsClient = await bruteratel.br_connect_handler(args.user, args.password, args.handler)
    print("[+] Authentication success")

    if args.list == "logs" or args.list == "downloads":
        archiveInfo = await bruteratel.br_list_archive(wsClient, args.list)
        if archiveInfo is not None:
            print("[+] Archive info:")
            if args.list == "logs":
                for ts, fileList in archiveInfo.items():
                    if ts == "dir":
                        pass
                    elif ts == "file":
                        for fName, fSize in fileList.items():
                            print("  - %-31s : %s bytes" % (fName,fSize) )
                    else:
                        for _, fileInfo in fileList.items():
                            for fName, fSize in fileInfo.items():
                                # print(f"  - {ts}\{fName} : {fSize} bytes")
                                print("  - %s\%-20s : %s bytes" % (ts,fName,fSize) )
            if args.list == "downloads":
                if 'file' in archiveInfo:
                    fileInfo = archiveInfo['file']
                    if len(fileInfo) > 0:
                        for fName, fSize in fileInfo.items():
                            print("  - %-60s : %s bytes" % (fName,fSize) )
                    else:
                        print("[-] No downloaded files")
                else:
                    print("[-] No downloaded files")
        else:
            print("[-] Error listing archive")
    else:
        parser.print_help()

    await wsClient.close(1000)

if __name__ == "__main__":
    asyncio.run(main())
