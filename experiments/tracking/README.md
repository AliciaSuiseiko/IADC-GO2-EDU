# Panoramic Tracking Evaluation Records

This directory preserves compact result summaries from the September 2026 server-side tracking audit. The corresponding evaluation and deployment code is in [`software/scripts/tracking`](../../software/scripts/tracking/).

These are engineering baselines, not claims of a new tracking algorithm or state-of-the-art performance. QuadTrack images and annotations, third-party model weights, raw predictions, and visualization videos are not redistributed.

## Files

| File | Evaluation | Important boundary |
| --- | --- | --- |
| `quadtrack_mot_baselines.json` | YOLO11n with BoT-SORT and ByteTrack on QuadTrack training sequences 0015-0017 | Generic tracking-by-detection control; low recall limits both trackers. |
| `quadtrack_sot_matrix.json` | Target-centred cylindrical-view SOT on selected identities from sequences 0015-0017 | Each target is initialized from its ground-truth first-frame box. Results are not open-set target acquisition scores. |
| `quadtrack_reid_summary.json` | OSNet identity separation on 120 annotated crops sampled from sequence 0017 | Ground-truth boxes are used to isolate appearance discrimination from detection and tracking errors. |
| `quadtrack_recovery_yolo11x.json` | Recovery after 12 annotated visibility gaps across three targets | Three events were recovered. The remaining failures were dominated by missing detector proposals for small people. |

## Main observations

- ByteTrack reached an overall IDF1 of `0.124`, compared with `0.094` for BoT-SORT in this detector-limited control. Recall remained only `0.135` and `0.126`, respectively, so the comparison does not establish a generally better tracker.
- Six of seven selected SOT targets achieved at least `97.8%` success at circular IoU >= 0.5. Target 9 in sequence 0017 failed almost completely, reducing the matrix average to approximately `85.6%`. Reporting the failed target is important because it exposes the identity/recovery case hidden by easier continuous tracks.
- The isolated ReID test reached `89.2%` rank-1 accuracy on 120 annotated samples. This is an appearance-module diagnostic, not an end-to-end person-following result.
- The stronger two-stage YOLO11x recovery scan recovered `3/12` annotated gaps. This negative result motivated treating proposal recall as a first-class limitation instead of only relaxing ReID or motion gates.

Metric implementations and launch parameters are versioned with the scripts. The broader deployment status, including real X5 throughput and DAP latency, is documented in [`PANORAMA_PERSON_TRACKER.md`](../../software/scripts/tracking/PANORAMA_PERSON_TRACKER.md).

## 中文说明

这里保存的是服务器实验中最有复核价值的结构化摘要，而不是完整日志或数据集副本。MOT、SOT、ReID 和遮挡恢复测试均使用 QuadTrack 训练集中的标注进行评估。其中 SOT 使用目标首帧真值框初始化，ReID 使用真值框裁剪，因此不能把这些数字表述成开放环境下端到端自动跟随的成功率。

保留失败结果同样重要：普通检测器召回率限制了 MOT，目标 9 的长时跟踪基本失败，而更强的恢复检测器也只恢复了 12 个遮挡事件中的 3 个。这些结果用于确定后续工作重点，不用于包装成新算法贡献。
