import secrets

def generate_secure_token(length=20):
    # 使用更广泛的字符集生成令牌
    token = secrets.token_urlsafe(length)
    return token[:length]

# 生成一个包含特殊字符的20位安全令牌
secure_token = generate_secure_token(20)
print("Secure Token:", secure_token)