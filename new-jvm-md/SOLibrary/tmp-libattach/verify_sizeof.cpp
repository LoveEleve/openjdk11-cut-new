#include <cstdio>
#include <sys/un.h>
#include <cstdint>

// 模拟 AttachOperation 结构（简化版，只计算 sizeof）
struct AttachOperation {
    char _name[16+1];        // name_length_max = 16
    char _arg[3][1024+1];    // arg_count_max = 3, arg_length_max = 1024
};

// 模拟 LinuxAttachOperation
struct LinuxAttachOperation : public AttachOperation {
    int _socket;
};

int main() {
    printf("========== libattach.so 数据结构验证 ==========\n\n");
    
    printf("1. AttachOperation sizeof 验证\n");
    printf("   sizeof(AttachOperation) = %lu bytes\n", sizeof(AttachOperation));
    printf("   理论计算：17 + 1025*3 = %d bytes\n", 17 + 1025*3);
    printf("   差异：%ld bytes（对齐填充）\n\n", sizeof(AttachOperation) - (17 + 1025*3));
    
    printf("2. LinuxAttachOperation sizeof 验证\n");
    printf("   sizeof(LinuxAttachOperation) = %lu bytes\n", sizeof(LinuxAttachOperation));
    printf("   理论计算：sizeof(AttachOperation) + 4 = %lu bytes\n", sizeof(AttachOperation) + 4);
    printf("   差异：%ld bytes（继承对齐）\n\n", sizeof(LinuxAttachOperation) - sizeof(AttachOperation) - 4);
    
    printf("3. sockaddr_un sizeof 验证\n");
    printf("   sizeof(struct sockaddr_un) = %lu bytes\n", sizeof(struct sockaddr_un));
    printf("   sun_family = %lu bytes\n", sizeof(((struct sockaddr_un*)0)->sun_family));
    printf("   sun_path = %lu bytes\n", sizeof(((struct sockaddr_un*)0)->sun_path));
    printf("   理论计算：2 + 108 = 110 bytes\n\n");
    
    printf("4. AttachOperation 字段偏移量\n");
    AttachOperation op;
    printf("   _name 偏移 = %lu bytes\n", (uint8_t*)&op._name - (uint8_t*)&op);
    printf("   _arg[0] 偏移 = %lu bytes\n", (uint8_t*)&op._arg[0] - (uint8_t*)&op);
    printf("   _arg[1] 偏移 = %lu bytes\n", (uint8_t*)&op._arg[1] - (uint8_t*)&op);
    printf("   _arg[2] 偏移 = %lu bytes\n", (uint8_t*)&op._arg[2] - (uint8_t*)&op);
    
    return 0;
}
