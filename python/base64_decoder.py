import base64

def base64_decode_fixed_value(encoded_string):
    try:
        # 将Base64编码的字符串解码为字节数组
        decoded_bytes = base64.b64decode(encoded_string)
        
        # 将字节数组转换为字符串
        decoded_string = decoded_bytes.decode('utf-8')
        
        return decoded_string
    except Exception as e:
        return f"解码错误: {str(e)}"

# 用你的固定Base64编码字符串替换下面的示例字符串
encoded_value = "xxx" #更换此内容

# 调用函数进行解码
decoded_value = base64_decode_fixed_value(encoded_value)

# 打印解码结果
print("解码结果:", decoded_value)
