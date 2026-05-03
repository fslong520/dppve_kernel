#!/usr/bin/python3
# -- coding: UTF-8 --

import gi
import os
import shutil
import glob
import re
import sys
gi.require_version('OSTree', '1.0')
from gi.repository import OSTree
from gi.repository import Gio

vmlinuz_files = []
initrd_files = []

def update_bootconfig(deployments,boot_index):
    try:
        bootconfig_parser = OSTree.BootconfigParser.new()
        conf_number = deployments - boot_index
        file_path = f"/boot/loader/entries/ostree-{conf_number}.conf"

        if not os.path.exists(file_path):
            print(f"Error: Directory {file_path} does not exist.")
            sys.exit(1)

        file = Gio.File.new_for_path(file_path)

        if bootconfig_parser.parse(file, cancellable=None):
            keys = ["linux", "initrd", "linuxTotal", "initrdTotal"]
            for key in keys:
                value = bootconfig_parser.get(key)
                match key:
                    case "linux" if value != vmlinuz_files[0]:
                        bootconfig_parser.set(key, vmlinuz_files[0])
                    case "initrd" if value != initrd_files[0]:
                        bootconfig_parser.set(key, initrd_files[0])
                    case "linuxTotal":
                        bootconfig_parser.set(key, ' '.join(vmlinuz_files))
                    case "initrdTotal":
                        bootconfig_parser.set(key, ' '.join(initrd_files))

            bootconfig_parser.write(file, cancellable=None)
        else:
            print("Failed to parse the boot config.")

    except Exception as e:
        print(f"Error parsing bootconfig: {e}")


def move_vmlinuz_and_initrd(file_path):
    global vmlinuz_files, initrd_files

    version=os.getenv("version")
    update_dir=os.getenv("update_dir")

    ###move
    if version and update_dir:
        if 'postinst' in update_dir:
            try:
                for file in glob.glob(f"/boot/vmlinuz-{version}"):
                    if os.path.exists(file):
                        print(f"ostree move file: {file}")
                        shutil.move(file, os.path.join(file_path, os.path.basename(file)))
            except Exception as e:
                print(f"Error occurred while moving files: {e}")

    ###delete
    if version and update_dir:
        if 'postrm' in update_dir:
            files_to_delete = [
                os.path.join(file_path, f"vmlinuz-{version}"),
                os.path.join(file_path, f"initramfs-{version}.img")
            ]

            for delete_file_path in files_to_delete:
                if os.path.exists(delete_file_path):
                    try:
                        os.remove(delete_file_path)
                        print(f"Deleted: {delete_file_path}")
                    except Exception as e:
                        print(f"Error deleting {delete_file_path}: {e}")
    ###save
    try:
        all_files = [
            os.path.join(file_path, file)
            for file in os.listdir(file_path)
            if os.path.isfile(os.path.join(file_path, file))
        ]

        vmlinuz_pattern = re.compile(r'vmlinuz-(.+)$')
        initrd_pattern = re.compile(r'initramfs-(.+)\.img$')

        tmp_vmlinuz_files = []
        tmp_initrd_files = []

        for file_path in all_files:
            file_name = os.path.basename(file_path)
            vmlinuz_match = vmlinuz_pattern.match(file_name)
            if vmlinuz_match:
                tmp_vmlinuz_files.append(file_path.replace('/boot', '', 1))
            initrd_match = initrd_pattern.match(file_name)
            if initrd_match:
                tmp_initrd_files.append((file_path.replace('/boot', '', 1)))

        ###sort
        vmlinuz_files = sorted(tmp_vmlinuz_files, key=lambda x: re.search(r'(\d+\.\d+[\.\d-]*)', x).group(1) if re.search(r'(\d+\.\d+[\.\d-]*)', x) else "", reverse=True)
        initrd_files = sorted(tmp_initrd_files, key=lambda x: re.search(r'(\d+\.\d+[\.\d-]*)', x).group(1) if re.search(r'(\d+\.\d+[\.\d-]*)', x) else "", reverse=True)

        print(f"ostree grub loader vmlinuz path : {vmlinuz_files}")
        print(f"ostree grub loader initramfs path : {initrd_files}")

    except Exception as e:
        print(f"Error accessing path '{file_path}': {e}")

def main(action):
    sysroot = OSTree.Sysroot.new(None)
    sysroot.set_mount_namespace_in_use()
    sysroot.initialize()
    sysroot.load()
    booted_deployment = sysroot.get_booted_deployment()

    if booted_deployment:
        osname = booted_deployment.get_osname()
        bootcsum = booted_deployment.get_bootcsum()
        file_path = os.path.join('/boot/ostree', f'{osname}-{bootcsum}')
        if not os.path.exists(file_path):
            print(f"Error: Directory {file_path} does not exist.")
            sys.exit(1)

        move_vmlinuz_and_initrd(file_path)

        if action == "move":
            sys.exit(0)

        boot_index = booted_deployment.get_index()
        deployments = len(sysroot.get_deployments())
        bootconfig = booted_deployment.get_bootconfig()

        if bootconfig:
            if len(vmlinuz_files) == len(initrd_files):
                update_bootconfig(deployments, boot_index)
            else:
                mismatch_msg = (
                    f"Mismatch in the number of vmlinuz and initrd files. "
                    f"vmlinuz files: {len(vmlinuz_files)}, initrd files: {len(initrd_files)}."
                )
                print(mismatch_msg)
                sys.exit(1)
        else:
            print("No bootconfig found in the booted deployment.")
    else:
        print("No booted deployment found.")

if __name__ == "__main__":
    if len(sys.argv) > 1:
        action = sys.argv[1]
        main(action)
    else:
        print("Usage:   python3 /usr/bin/ostree-update-kernel.py <action>")
        print("Action:")
        print("    move   : move vmlinuz and initrafms file to ostree boot folders")
        print("    update : move files and update ostree boot conf")

