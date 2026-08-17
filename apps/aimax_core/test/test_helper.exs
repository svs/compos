# A checkpoint outlives the run that wrote it, so the test home fills up.
# Every test that reads the buffer catalog then walks all of them: 1438 stale
# checkpoints took one 7-test file from 0.6s to 140s. Start each run empty.
File.rm_rf!(Path.join(Application.get_env(:aimax_core, :home), "buffers"))

ExUnit.start()
