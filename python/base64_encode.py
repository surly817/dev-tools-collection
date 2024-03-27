import base64

def base64_encode(input_string):
    # 将字符串转换为字节码
    byte_data = input_string.encode('utf-8')

    # 使用 base64 编码
    encoded_data = base64.b64encode(byte_data)

    # 将字节码解码为字符串
    encoded_string = encoded_data.decode('utf-8')

    return encoded_string

if __name__ == "__main__":
    # 示例输入字符串
    input_string = "xxx"

    # 进行 Base64 编码
    encoded_result = base64_encode(input_string)

    # 输出结果
    print(f"Input String: {input_string}")
    print(f"Encoded Result: {encoded_result}")
