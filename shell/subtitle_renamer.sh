#!/bin/bash
# Young.Sheldon.S07E09.A Fancy Article and a Scholarship for a Baby 1080p AMZN WEB-DL DDP5 1 H 264-NTb.英文.srt 
#改名为 YoungSheldonS07E09英文.srt

# 定义一个函数，用于提取目标文件名前缀
extract_prefix() {
  local filename="$1"
  # 使用正则表达式匹配并提取文件名前缀部分
  if [[ "$filename" =~ ([Yy]oung[[:space:]\.]*[Ss]heldon[[:space:]\.]*[Ss][0-9]{2}[[:space:]\.]*[Ee][0-9]{2}) ]]; then
    local prefix="${BASH_REMATCH[1]}"
    # 去除文件名前缀中的非字母数字字符和空格
    prefix=$(echo "$prefix" | sed 's/[^a-zA-Z0-9]//g')
    
    # 使用正则表达式匹配最后的中文部分，包括“繁体”、“简体”、“繁体&英文”或其他中文
     if [[ "$filename" =~ \.?(繁体|简体|英文)(\&英文)? ]]; then
      local chinese_suffix="${BASH_REMATCH[0]}"
      prefix="${prefix}${chinese_suffix}"
    else
      # 匹配任意中文部分，且中文部分可能包含 '&' 字符
      if [[ "$filename" =~ .*[^a-zA-Z0-9]([^\x00-\x7F]+)$ ]]; then
        local chinese_suffix="${BASH_REMATCH[1]}"
        prefix="${prefix}${chinese_suffix}"
      fi
    fi
    
    echo "$prefix"
  else
    # 如果不匹配，返回空字符串
    echo ""
  fi
}

# 递归查找并重命名文件
rename_files() {
  local dir="$1"
  find "$dir" -type f | while IFS= read -r file; do
    local basename=$(basename "$file")
    local dirname=$(dirname "$file")
    local ext="${basename##*.}"
    # 获取文件名前缀部分
    new_prefix=$(extract_prefix "$basename")
    # 如果提取到的前缀不为空，并且文件名未被修改过，则进行重命名
    if [[ -n "$new_prefix" && "$basename" != "$new_prefix.$ext" ]]; then
      new_name="${new_prefix}.${ext}"
      new_path="${dirname}/${new_name}"
      echo "Renaming '$file' to '$new_path'"
      mv "$file" "$new_path"
    fi
  done
}

# 调用函数处理当前目录及其子目录
rename_files "."

echo "文件重命名完成"
