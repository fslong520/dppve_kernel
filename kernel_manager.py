import os
import subprocess


def load_installed():
    """加载已安装内核"""
    res = subprocess.Popen("sudo ls /boot", shell=True, stdout=subprocess.PIPE)
    print("检测到系统里安装的内核有：")
    cnt = 1
    versions = []
    for line in res.stdout:
        line = line.decode("utf-8", "ignore").strip()
        if line.startswith("config-"):
            version = line.split("config")[1]
            print(f"    {cnt}. linux-image{version}")
            cnt += 1
            versions.append(version)


if __name__ == "__main__":
    versions = load_installed()
