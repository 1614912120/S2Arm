// 原创灰阶经生产呈现路径读回交换链；期望为输入编码字节，UNORM 是负对照。
#define main unused_fixture_main
#define vkGetSwapchainImagesKHR fixture_GetSwapchainImagesKHR
#define vkQueuePresentKHR fixture_QueuePresentKHR
#include "t_backend_vk.c"
#undef main
#undef vkGetSwapchainImagesKHR
#undef vkQueuePresentKHR

static VkExtent2D probe_extent;
static VkFormat probe_format;
static VkImage probe_images[64];
static unsigned probe_active, probe_value, probe_bars, probe_cases;
static uint64_t probe_bad, probe_pixels;
// 只从真实驱动公布的格式中选择，分别验证 RGBA / BGRA 交换链，绝不伪造能力。
VKAPI_ATTR VkResult VKAPI_CALL vkGetPhysicalDeviceSurfaceFormatsKHR(VkPhysicalDevice dev, VkSurfaceKHR surface, uint32_t *n, VkSurfaceFormatKHR *out) {
    PFN_vkGetPhysicalDeviceSurfaceFormatsKHR real = (PFN_vkGetPhysicalDeviceSurfaceFormatsKHR)dlsym(RTLD_NEXT,"vkGetPhysicalDeviceSurfaceFormatsKHR");
    VkSurfaceFormatKHR available[64]; uint32_t count=64;
    VkResult r=real(dev,surface,&count,available);if(r!=VK_SUCCESS)return r;
    VkFormat want=getenv("S2A_TEST_PRESENT_BGRA")?VK_FORMAT_B8G8R8A8_UNORM:VK_FORMAT_R8G8B8A8_UNORM;
    for(uint32_t i=0;i<count;i++) if(available[i].format==want && available[i].colorSpace==VK_COLOR_SPACE_SRGB_NONLINEAR_KHR) {
        if(out && !*n)return VK_INCOMPLETE;
        if(out)*out=available[i];*n=1;return VK_SUCCESS;
    }
    CHECK(0,"真实表面不支持待测格式 %d",(int)want);return VK_ERROR_FORMAT_NOT_SUPPORTED;
}
VKAPI_ATTR VkResult VKAPI_CALL vkCreateSwapchainKHR(VkDevice dev, const VkSwapchainCreateInfoKHR *ci, const VkAllocationCallbacks *a, VkSwapchainKHR *out) {
    PFN_vkCreateSwapchainKHR real = (PFN_vkCreateSwapchainKHR)vkGetDeviceProcAddr(dev,"vkCreateSwapchainKHR");
    VkSurfaceCapabilitiesKHR caps;
    CHECK(vkGetPhysicalDeviceSurfaceCapabilitiesKHR(g_dev.physical,ci->surface,&caps)==VK_SUCCESS && (caps.supportedUsageFlags & VK_IMAGE_USAGE_TRANSFER_SRC_BIT),"probe surface must support readback");
    VkSwapchainCreateInfoKHR copy=*ci; copy.imageUsage |= VK_IMAGE_USAGE_TRANSFER_SRC_BIT;
    probe_extent=ci->imageExtent; probe_format=ci->imageFormat;
    return real(dev,&copy,a,out);
}
VKAPI_ATTR VkResult VKAPI_CALL vkGetSwapchainImagesKHR(VkDevice d,VkSwapchainKHR s,uint32_t *n,VkImage *im) {
    VkResult r=fixture_GetSwapchainImagesKHR(d,s,n,im);
    if(r==VK_SUCCESS && im && *n<=64) memcpy(probe_images,im,*n*sizeof *im);
    return r;
}
static void probe_readback(VkQueue q, VkImage image) {
    VkDevice d=g_dev.device;
    VkDeviceSize bytes=(VkDeviceSize)probe_extent.width*probe_extent.height*4;
    VkBufferCreateInfo bi={.sType=VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,.size=bytes,.usage=VK_BUFFER_USAGE_TRANSFER_DST_BIT};
    VkBuffer b; CHECK(vkCreateBuffer(d,&bi,NULL,&b)==VK_SUCCESS,"probe buffer");
    VkMemoryRequirements req; vkGetBufferMemoryRequirements(d,b,&req);
    uint32_t mt=s2a_vk_memory_type(&g_dev,req.memoryTypeBits,VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT|VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,0);
    VkMemoryAllocateInfo ai={.sType=VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,.allocationSize=req.size,.memoryTypeIndex=mt};
    VkDeviceMemory mem; CHECK(vkAllocateMemory(d,&ai,NULL,&mem)==VK_SUCCESS,"probe memory");
    CHECK(vkBindBufferMemory(d,b,mem,0)==VK_SUCCESS,"probe binding");
    VkCommandPoolCreateInfo pci={.sType=VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,.queueFamilyIndex=g_dev.queue_family};
    VkCommandPool pool; CHECK(vkCreateCommandPool(d,&pci,NULL,&pool)==VK_SUCCESS,"probe pool");
    VkCommandBufferAllocateInfo cai={.sType=VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,.commandPool=pool,.level=VK_COMMAND_BUFFER_LEVEL_PRIMARY,.commandBufferCount=1};
    VkCommandBuffer cb; CHECK(vkAllocateCommandBuffers(d,&cai,&cb)==VK_SUCCESS,"probe cmd");
    VkCommandBufferBeginInfo begin={.sType=VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
    CHECK(vkBeginCommandBuffer(cb,&begin)==VK_SUCCESS,"probe begin");
    VkImageMemoryBarrier bar={.sType=VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,.srcAccessMask=VK_ACCESS_TRANSFER_WRITE_BIT,.dstAccessMask=VK_ACCESS_TRANSFER_READ_BIT,.oldLayout=VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,.newLayout=VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,.srcQueueFamilyIndex=VK_QUEUE_FAMILY_IGNORED,.dstQueueFamilyIndex=VK_QUEUE_FAMILY_IGNORED,.image=image,.subresourceRange={VK_IMAGE_ASPECT_COLOR_BIT,0,1,0,1}};
    vkCmdPipelineBarrier(cb,VK_PIPELINE_STAGE_TRANSFER_BIT,VK_PIPELINE_STAGE_TRANSFER_BIT,0,0,NULL,0,NULL,1,&bar);
    VkBufferImageCopy region={.imageSubresource={VK_IMAGE_ASPECT_COLOR_BIT,0,0,1},.imageExtent={probe_extent.width,probe_extent.height,1}};
    vkCmdCopyImageToBuffer(cb,image,VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,b,1,&region);
    bar.srcAccessMask=VK_ACCESS_TRANSFER_READ_BIT; bar.dstAccessMask=0;bar.oldLayout=VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;bar.newLayout=VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
    vkCmdPipelineBarrier(cb,VK_PIPELINE_STAGE_TRANSFER_BIT,VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT,0,0,NULL,0,NULL,1,&bar);
    CHECK(vkEndCommandBuffer(cb)==VK_SUCCESS,"probe end");
    VkFenceCreateInfo fi={.sType=VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};VkFence f;
    CHECK(vkCreateFence(d,&fi,NULL,&f)==VK_SUCCESS,"probe fence");
    VkSubmitInfo si={.sType=VK_STRUCTURE_TYPE_SUBMIT_INFO,.commandBufferCount=1,.pCommandBuffers=&cb};
    CHECK(vkQueueSubmit(q,1,&si,f)==VK_SUCCESS,"probe submit");
    CHECK(vkWaitForFences(d,1,&f,VK_TRUE,5000000000ull)==VK_SUCCESS,"probe wait");
    uint8_t *data=NULL; CHECK(vkMapMemory(d,mem,0,bytes,0,(void **)&data)==VK_SUCCESS,"probe map");
    uint64_t bad=0; unsigned first=0;
    for(uint32_t y=0;y<probe_extent.height;y++) for(uint32_t x=0;x<probe_extent.width;x++) {
        int inside=!probe_bars || (x>=40 && x<280 && y>=20 && y<160);
        unsigned want=inside?probe_value:0, alpha=inside?128:255;
        const uint8_t *p=data+4*((size_t)y*probe_extent.width+x);
        int mismatch=abs((int)p[0]-(int)want)>1 || abs((int)p[1]-(int)want)>1 || abs((int)p[2]-(int)want)>1 || p[3]!=alpha;
        if(mismatch && !bad) first=p[0];
        bad+=mismatch;probe_pixels++;
    }
    probe_cases++;probe_bad+=bad;
    printf("PRESENT_PIXELS case=%u format=%d expected=%u firstBad=%u bad=%llu bars=%u\n",probe_cases,(int)probe_format,probe_value,first,(unsigned long long)bad,probe_bars);
    vkUnmapMemory(d,mem);vkDestroyFence(d,f,NULL);vkDestroyCommandPool(d,pool,NULL);vkDestroyBuffer(d,b,NULL);vkFreeMemory(d,mem,NULL);
}
VKAPI_ATTR VkResult VKAPI_CALL vkQueuePresentKHR(VkQueue q,const VkPresentInfoKHR *pi) {
    if(probe_active) probe_readback(q,probe_images[pi->pImageIndices[0]]);
    return fixture_QueuePresentKHR(q,pi);
}
int main(void) {
    char why[256]={0};if(s2a_vk_device_create(&g_dev,why,sizeof why)) {fprintf(stderr,"device %s\n",why);return 2;}
    memset(&g_desc,0,sizeof g_desc);g_desc.host_device=&g_dev;g_desc.app_label="original-present-grayscale";
    if(!open_backend())return 2;
    nvn_gpu_err e={0};nvn_gpu_surface sf=NULL;CHECK(OK(nvn_gpu_surface_attach((void *)1,&sf,&e)),"attach %s",e.why);
    if(!sf)return 2;
    const uint32_t formats[]={NVN_FORMAT_RGBA8_SRGB,NVN_FORMAT_RGBA8,NVN_FORMAT_BGRA8_SRGB,NVN_FORMAT_BGRA8};
    const unsigned values[]={0,16,64,128,200,255}; uint64_t ticket=1;
    for(unsigned fmt=0;fmt<4;fmt++) for(unsigned filter=0;filter<2;filter++) for(unsigned val=0;val<6;val++) {
        nvn_gpu_tex t=make_tex(64,36,formats[fmt],NVN_GPU_TEX_SAMPLED|NVN_GPU_TEX_CPU_UPLOAD);
        nvn_gpu_view v=make_view(t);uint8_t pixels[64*36*4];
        for(unsigned p=0;p<64*36;p++){pixels[p*4]=pixels[p*4+1]=pixels[p*4+2]=values[val];pixels[p*4+3]=128;}
        nvn_gpu_cmd c=begin_cmd();nvn_gpu_tex_upload(c,t,0,0,NULL,pixels,64*4,sizeof pixels);
        CHECK(OK(nvn_gpu_cmd_commit(c,ticket,on_done,NULL,&e)),"upload %s",e.why);
        nvn_gpu_drawable dr={0};CHECK(OK(nvn_gpu_drawable_acquire(sf,1000000000ull,NULL,&dr,&e)),"acquire %s",e.why);
        nvn_gpu_present_desc pd={0};pd.src=v;pd.filter=filter;pd.flip_y=filter;
        probe_bars=filter; if(probe_bars){pd.crop[0]=4;pd.crop[1]=2;pd.crop[2]=48;pd.crop[3]=24;pd.dst[0]=40;pd.dst[1]=20;pd.dst[2]=240;pd.dst[3]=140;}
        probe_value=values[val];probe_active=1;
        CHECK(OK(nvn_gpu_present(sf,&dr,&pd,ticket,on_shown,NULL,&e)),"present %s",e.why);probe_active=0;
        CHECK(OK(nvn_gpu_fence_wait(ticket++,5000000000ull,&e)),"wait %s",e.why);
        nvn_gpu_view_release(v);nvn_gpu_tex_release(t);
    }
    CHECK(OK(nvn_gpu_surface_rebuild(sf,&e)),"rebuild encoding target %s",e.why);
    nvn_gpu_tex t=make_tex(64,36,NVN_FORMAT_RGBA8_SRGB,NVN_GPU_TEX_SAMPLED|NVN_GPU_TEX_CPU_UPLOAD);
    nvn_gpu_view v=make_view(t); uint8_t px[64*36*4];memset(px,128,sizeof px);
    nvn_gpu_cmd c=begin_cmd();nvn_gpu_tex_upload(c,t,0,0,NULL,px,64*4,sizeof px);
    CHECK(OK(nvn_gpu_cmd_commit(c,ticket,on_done,NULL,&e)),"post rebuild upload");
    nvn_gpu_drawable dr={0};CHECK(OK(nvn_gpu_drawable_acquire(sf,1000000000ull,NULL,&dr,&e)),"post rebuild acquire");
    nvn_gpu_present_desc pd={0};pd.src=v;probe_bars=0;probe_value=128;probe_active=1;
    CHECK(OK(nvn_gpu_present(sf,&dr,&pd,ticket,on_shown,NULL,&e)),"post rebuild present");probe_active=0;
    nvn_gpu_view_release(v);nvn_gpu_tex_release(t);
    // 不 detach：close 持 g_mu，仍须收掉带中间图的面，不能递归拿锁。
    CHECK(OK(nvn_gpu_close(5000000000ull,&e)),"close grayscale session");
    CHECK(open_backend(),"reopen lifecycle session");
    c71_present();
    CHECK(OK(nvn_gpu_close(5000000000ull,&e)),"close %s",e.why);s2a_vk_device_destroy(&g_dev,1);
    printf("PRESENT_RESULT cases=%u pixels=%llu bad=%llu API_failures=%d\n",probe_cases,(unsigned long long)probe_pixels,(unsigned long long)probe_bad,g_fail);
    return g_fail||probe_bad?1:0;
}
