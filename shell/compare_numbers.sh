#!/bin/bash

# 提示用户输入数字
echo "请输入数字1"
read num1

echo "请输入数字2"
read num2

# 比较数字大小
if [ "$num1" -eq "$num2" ]; then
	echo "$num1 = $num2"
elif [ "$num1" -gt "$num2" ]; then
	echo "$num1 > $num2"
else
	echo "$num1 < $num2"
fi
