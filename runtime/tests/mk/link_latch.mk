# native-test-link_latch：显示链路晚锁存等待上界 + 出图队列排空判定 + 帧步进扣除排空（纯函数，不连宿主 / Metal；DM_PRESENT_LATCH，nxnative 60284e79，MIT）
NATIVE_TEST_OWN += link_latch
$(BUILD)/tests/t_link_latch: graphics/nvn/tests/t_link_latch.c graphics/nvn/gfx/nvn/nvn_link_latch.h
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -Igraphics/nvn/gfx/nvn -o $@ graphics/nvn/tests/t_link_latch.c -lm
$(BUILD)/tests/t_link_drain: graphics/nvn/tests/t_link_drain.c graphics/nvn/gfx/nvn/nvn_link_drain.h graphics/nvn/gfx/nvn/nvn_fstep.h
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -Wno-unused-function -Igraphics/nvn/gfx/nvn -o $@ graphics/nvn/tests/t_link_drain.c -lm
.PHONY: native-test-link_latch
native-test-link_latch: $(BUILD)/tests/t_link_latch $(BUILD)/tests/t_link_drain
	$(BUILD)/tests/t_link_latch
	$(BUILD)/tests/t_link_drain
TEST_TARGETS += native-test-link_latch
