# It cannot be used to start business programs (systemd services can be started), only for SE6/8 operation and maintenance tools
## SE6/SE8 Batch Deployment and Configuration Tool
This application is designed for batch deployment and configuration of se6/se8. There are two ways to run this application:

1. Interactive mode by running `bmsec` directly.
2. Command-line execution.

### Command Line Execution Instructions:

#### Parameter Meanings

* `<localFile>`：Local file address.
* `<remoteFile>`：Remote target address.
* `<id>`：Core board ID，[1-N，all]
* `<cmd>`：Command to be executed on the target core board.

#### Running Examples

* Run a command remotely
  * bmsec run all ls
  * Execute `ls` on all compute boards.
* Upload a file:
  * `bmsec pf all /data/example.txt /data`
  * For example, transfer the `data/example.txt` file from the control board to the /data directory on all core boards.

### Feature List:

1. Print Help Documentation [help]
2. Print Configuration Information [pconf]
3. Execute Remote Command [run \<id> \<cmd>]
4. Get All Remote Device Information [getbi]
5. Upload File [pf \<id> \<localFile> \<remoteFile>]
6. Download File [df \<id> \<remoteFile> \<localFile>]
7. Connect to Specific SSH Session [ssh \<id>]
8. Restart Power of a Specific Core Node [reset \<id>]
9. Connect to Debug Serial Port of a Specific Core Node [uart \<id>]
10. Print Debug Serial Port of a Specific Core Node [puart \<id>]
11. Upgrade Specific Core Board Using Control Board's Built-in Firmware [update \<id>]
12. Check Current TFTP Upgrade Progress [tftpc]
13. Start NFS Service and Share with Compute Boards [nfs]
14. Batch Modify Memory Layout [cmem \<id> {\<p> / < \<c> \<npuSize> \<vpuSize> \<vppSize> >} [dtsFile]]
15. Reset cores config [rconf]
16. Package the system of a computing power node [sysbak <id> <localPath> [onlyBak]]
17. Edit port mappings to cores [pt \<opt> [\<hostIp> \<id> \<port1> \<port2> \<protocol>]]

### Important Notes:

After configuration (automatically configured for the first run, can be reset using the 'rconf' command).

If you have modified parameters such as SSH port and password for the computational core, you will need to modify the corresponding parameters in the 'configs/sub/subInfo.12' file within the installation directory.

## Update method

On our SFTP server 106.37.111.18:32022, the public account is open:open, located under /tools/bmsec, download the deb package and install it with 'dpkg -i'

## Build from source

Before building the bmsec deb package, you must first build socbak (`socbak.zip` is shipped inside `deb/opt/sophon/bmsec/binTools/`).

```bash
# 1. Build socbak first
cd source/psocbak
bash release.sh
cd -

# 2. Then build bmsec
cd source/pbmsec
bash release.sh
```

`pbmsec/release.sh` auto-syncs `socbak.zip` from `../psocbak/socbak.zip` into `deb/opt/sophon/bmsec/binTools/socbak.zip`. If the source zip is missing, it reuses the prebuilt one already in `binTools/`; if neither exists, it fails with an error.

If you don't want to build socbak yourself, you can also download a prebuilt `socbak.zip` from https://github.com/sophgo/sophon-tools/releases and place it at `source/psocbak/socbak.zip` (or directly at `source/pbmsec/deb/opt/sophon/bmsec/binTools/socbak.zip`), then run `pbmsec/release.sh`.

Dependencies: `pandoc`, `dpkg-deb`.

Output: `output/bmsec_v<version>.deb`.
