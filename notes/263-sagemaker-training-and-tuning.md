# SageMaker AI: モデルトレーニングとハイパーパラメータチューニング

MLパイプライン全体の位置づけは[260-sagemaker-ml-pipeline-overview.md](260-sagemaker-ml-pipeline-overview.md)を参照。

## ハイパーパラメータチューニング

**SageMaker Automatic Model Tuning（HPO）**が該当機能。目的関数（例: validation AUC）を指定すると、複数のトレーニングジョブを自動で並行/逐次実行し最適なハイパーパラメータの組み合わせを探索する。

| 探索戦略 | 概要 |
|------|------|
| Grid Search | 指定範囲を格子状に全探索。組み合わせ数が多いと非効率 |
| Random Search | ランダムにサンプリング。Grid Searchより少ない試行で同等以上の性能が出やすい |
| Bayesian Optimization | 過去の試行結果から次に試すべき値を確率モデルで予測しながら探索。デフォルト戦略で、試行回数が限られる場合に効率的 |
| Hyperband | 学習の早い段階で見込みの薄い試行を打ち切りつつ、有望な設定にリソースを重点配分するマルチアーム・バンディット的手法 |

- **Warm Start**: 過去のチューニングジョブの結果を引き継いで新しいチューニングを開始し、探索を効率化
- **Early Stopping**: 精度改善が頭打ちの試行を自動で打ち切り、無駄な計算コストを削減（正則化目的のEarly Stoppingとは別軸の、探索コスト削減のための機能）

## 正則化

過学習抑制の手法自体はローカルでの経験通り。L1（Lasso）/L2（Ridge）/ElasticNet、Dropout、Early Stopping（学習打ち切り）、Data Augmentationなど。AWS特有のサービスはなく、SageMakerの組み込みアルゴリズム（XGBoostの`alpha`/`lambda`等）やフレームワークコンテナ（PyTorch/TensorFlow）のハイパーパラメータとして、上記のAutomatic Model Tuningの探索対象に含める形で扱うのが実務上のポイント。

## 試験でのひっかけポイント整理

- 「Automatic Model TuningのEarly Stoppingは過学習対策のEarly Stoppingと同じ目的である」→ 要注意。前者はチューニング全体の**探索コスト削減**（見込みの薄い試行の打ち切り）、後者は個々のモデルの**過学習抑制**が目的で、レイヤーが異なる
