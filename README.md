# travos - Travel OS

OS for traveling. Meant to be installed on a USB key of size at least 128GB.

## Usage

Where `/dev/sdX` is your USB stick (WARNING: This will **erase all data** on `/dev/sdX`):

```bash
$ ./travos.sh /dev/sdX
```

If you don't have a USB stick, you can use `--test` to create a temporary image file and run [QEMU] on it:

```bash
$ ./travos.sh --test
```

Or you can use both to write the image to the USB key *and* start it with [QEMU]:

```bash
$ ./travos.sh --test /dev/sdX
```

## Partition scheme

In order to boot on as many computers as possible, the USB is formatted with a [hybrid GPT+MBR scheme](http://www.rodsbooks.com/gdisk/hybrid.html) inspired by [multibootusb].

* Partition 1, 32 MB: Unformatted MSDOS legacy boot partition.
* Partition 2, 8 GB: FAT32 EFI boot partition. (UUID: `B007-0EF1`, "boot EFI")
    * `/boot`: GRUB configuration and installation files, as copied from this repo's `/grub` directory.
    * `/isos`: ISO images for various live Linux distros.
    * `/bin`: Empty and unused; mostly just there to match `multibootusb`.
* Partition 3, 48 GB: LUKS+ext4 Arch Linux root partition. (UUID: `a5c8a5c8-a5c8-a5c8-a5c8-a5c8a5c8a5c8`, "arch"). Not yet implemented.
* Partition 4, rest of space: LUKS+ext4 home partition. (UUID: `803e803e-803e-803e-803e-803e803e803e`, "home"). Not yet implemented.

Partitions 1-3 are meant to be expendable and completely recreatable from this repository. Partition 4 is meant to be carried over from key to key.

### GRUB configuration

Most configuration is copied from [multibootusb], with changes to support the ISO images being on the EFI partition rather than the "data" one. This change is such that we save one partition.

## Supported live Linux distributions

* [Kali Linux](https://www.kali.org/). Current version: `2017.1`
* [System Rescue CD](https://www.system-rescue-cd.org/). Current version: `5.01`
* [Tails](https://tails.boum.org/). Current version: `2.12`

## Arch provisioning

TODO: Instructions on how to automatically customize the Arch installation.

## Licensing

As portions of this project are heavily based off [multibootusb] which is under the [GPLv3], this project is also licensed under [GPLv3].

[multibootusb]: https://github.com/aguslr/multibootusb
[GPLv3]: https://www.gnu.org/licenses/quick-guide-gplv3.en.html
[QEMU]: http://www.qemu.org/
