#! /bin/bash

echo 构建内核脚本，免去人工执行命令...
echo 自动安装依赖...
sudo apt build-dep -y linux
sudo apt install git wget build-essential libncurses5 libncurses5-dev 
sudo apt install zstd
sudo apt update
echo 下载-解压源码包...
wget https://gitlab.com/xanmod/linux/-/archive/6.6.7-xanmod1/linux-6.6.7-xanmod1.tar.gz
tar -xf linux-6.6.7-xanmod1.tar.gz
echo 复制config...
cp siyu.config linux-6.6.7-xanmod1/.config
cd linux-6.6.7-xanmod1
echo git部署防止报错...
git config --global user.name "Your Name"
git config --global user.email "youremail@yourdomain.com"
git init
git add .
git commit -m "1"
echo 配置...
make menuconfig
echo 开始编译deb...
make deb-pkg -j4
echo 完成退场...
cd ..
ls