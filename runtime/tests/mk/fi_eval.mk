# 补帧画质评测工具（不是单测，不进 TEST_TARGETS）：graphics/nvn/tests/fi_eval.m 含生产 nvn_mtl.m 源码 + 真 Metal 设备，tools/fi_eval.sh 调 make fi-eval-tool 编出来再跑
ifeq ($(S2A_UNAME),Darwin)
FI_EVAL_SOURCE ?= graphics/nvn/gfx/nvn/nvn_mtl.m
FI_EVAL_BINARY ?= $(BUILD)/tools/fi_eval
$(FI_EVAL_BINARY): CFLAGS += -I$(abspath $(NVN_TEST_DIR)/nvn/gen)
$(FI_EVAL_BINARY): graphics/nvn/tests/fi_eval.m $(FI_EVAL_SOURCE) $(NVN_MTL_DEPS) $(dir $(FI_EVAL_SOURCE))nvn_session.inc $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -O2 -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -DFI_EVAL_SOURCE='"$(abspath $(FI_EVAL_SOURCE))"' \
	  -o $@ graphics/nvn/tests/fi_eval.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/../tests/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: fi-eval-tool
fi-eval-tool: $(FI_EVAL_BINARY)
endif
