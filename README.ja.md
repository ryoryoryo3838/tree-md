# tree-md

[![CI](https://github.com/ryoryoryo3838/tree-md/actions/workflows/ci.yml/badge.svg)](https://github.com/ryoryoryo3838/tree-md/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)
[![OCaml](https://img.shields.io/badge/OCaml-%3E%3D5.3.0-ec6813.svg)](https://ocaml.org)

**ノートは Markdown で書き、[Forester](https://www.forester-notes.org/) で公開する。**

`tree-md` は厳格な Markdown 方言（`.tree.md`）を決定的な Forester `.tree`
ソースへコンパイルします。見出しは入れ子の subtree に、Obsidian 形式の
Wiki リンクと埋め込みは tree 参照とトランスクルージョンになり、生成される
ファイルはすべてマニフェスト管理・ハッシュ検証済みで、バイト単位で再現可能です。

English version: [README.md](./README.md)

---

## なぜ必要か

Forester はハイパーテキストによる数学的文章のための優れたツールですが、その
`.tree` ソースは独自のマークアップ言語です。すでに Obsidian やエディタ、git
リポジトリで Markdown によるノートを運用しているなら、それを捨てるか、二重に
管理するかの選択を迫られます。

`tree-md` は Markdown を唯一の情報源（source of truth）のままにします。
`.tree.md` ファイルを通常の Markdown ツールで編集し、`tree-md build` が
Forester の読む `.tree` ファイルを生成します。

本ツールは意図的に **厳格** です。忠実に変換できない Markdown は、黙って
無視したり素通しにしたりせず、診断メッセージとソース抜粋つきで拒否します。
以下の表にあるすべての構文には定義された出力があり、それ以外はコンパイルされません。

`tree-md` は Forester から独立しています。Forester のコードはリンクされません。
対象は `forester-6.0-dev` ブランチのコミット
`30b73641cef02433ee158db6ddc77f7b49de60be` のソース言語と CLI 挙動です。

## 概観

<table>
<tr><th><code>notes.tree.md</code></th><th><code>notes.tree</code></th></tr>
<tr valign="top"><td>

```markdown
---
date: 2026-08-02
taxon: Note
authors:
  - "[[miya]]"
  - "Ada Lovelace"
tags:
  - compiler
---

# Complete Example

A paragraph with **bold** and `code`.

<!-- subtree: my-sec -->
## Named Section

A [[wiki-link]] and math $x^2$.

![[standalone-embed]]
```

</td><td>

```tree
\title{Complete Example}
\date{2026-08-02}
\taxon{Note}
\author{miya}
\author/literal{Ada Lovelace}
\tag{compiler}

\p{A paragraph with \strong{bold} and \code{code}.}

\subtree[my-sec]{
\title{Named Section}
\p{A [[wiki-link]] and math #{x^2}.}
\transclude{standalone-embed}
}
```

</td></tr>
</table>

## 動作要件

- OCaml 5.3.0 以上
- Dune 3.22 以上
- Forester 6.0-dev（生成された tree のレンダリング用。`tree-md` の実行には不要）

## インストール

### opam でソースから

```bash
git clone https://github.com/ryoryoryo3838/tree-md.git
cd tree-md
opam install .
```

opam switch に `tree-md` 実行ファイルがインストールされます。

### Dune パッケージ管理でソースから

本リポジトリは OCaml コンパイラを含む依存関係の全閉包を
[`dune.lock/`](./dune.lock) に固定しています。opam switch は不要です。

```bash
git clone https://github.com/ryoryoryo3838/tree-md.git
cd tree-md
dune build           # 固定された閉包を取得してビルド
dune exec -- tree-md --version
```

### devbox で

[`devbox.json`](./devbox.json) は開発および CI で使用しているものと同一の
ツールチェインを提供します。

```bash
devbox shell
dune build
```

## クイックスタート

`tree-md` のワークスペースは Forester の forest と並べて配置します。
次のレイアウトを作成してください。

```text
my-forest/
├── forest.toml          # Forester 自体の設定
├── tree-md.toml         # tree-md の設定
├── trees-md/            # 自分で書く Markdown ソース
│   └── index.tree.md
├── trees/               # 手書きの .tree ファイル（任意）
└── generated/           # tree-md の出力先 — 手で編集しないこと
```

**1. `tree-md.toml` を設定する:**

```toml
version = 1
forest  = "forest.toml"
sources = ["trees-md"]
output  = "generated"
target  = "forester-6.0-dev@30b73641cef02433ee158db6ddc77f7b49de60be"
```

**2. `forest.toml` の `[forest].trees` に出力ルートを含める:**

```toml
[forest]
trees  = ["trees", "generated"]
assets = ["assets"]
```

**3. `trees-md/index.tree.md` を書く:**

```markdown
---
taxon: Note
---

# Hello, forest

This is my first tree, with a [[reference]] to another one.
```

**4. ビルドする:**

```console
$ tree-md build
build: 1 created, 0 replaced, 0 deleted, 0 unchanged

$ tree-md check          # 読み取り専用。生成状態がクリーンか確認する
$ forester build forest.toml
```

`tree-md build` が `generated/index.tree` を書き出し、`forester build` が
forest 全体をサイトに変換します。

---

# Markdown 記法と tree 記法の対応

これが言語仕様の全体です。ここに記載のない構文は拒否されます。

## ドキュメントの形

| 規則 | 内容 |
| --- | --- |
| 拡張子 | 厳密に `.tree.md` |
| エンコーディング | UTF-8、**BOM なし**（先頭 BOM は `TM003`） |
| 探索 | 再帰的。シンボリックリンクは辿らない。ドットで始まる要素を含むパスは無視 |
| 出力パス | ディレクトリ構造を反映し、ファイル名は同一性になる。`trees-md/a/foo.tree.md` → `generated/a/foo.tree`。`id: mlnet-7` があれば `generated/a/mlnet-7.tree` |
| tree の同一性 | フロントマターの `id`、無ければ**ファイル名の語幹**（`foo`）。パス（`a/foo`）ではない。forest 内で同一性が重複するとエラー |

## フロントマター

YAML フロントマターは任意です。使う場合はファイル先頭に置き、`---` で囲みます。

| Markdown フロントマター | Forester 出力 |
| --- | --- |
| `id: mlnet-7` | *(出力なし)* — tree の同一性。後述 |
| `date: 2026-08-02` | `\date{2026-08-02}` |
| `taxon: Note` | `\taxon{Note}` |
| `authors: ["[[miya]]"]` | `\author{miya}` — tree 参照 |
| `authors: ["Ada Lovelace"]` | `\author/literal{Ada Lovelace}` — 文字列リテラル |
| `contributors: [...]` | `\contributor{...}` / `\contributor/literal{...}`（同じ規則） |
| `tags: [compiler]` | `\tag{compiler}` |
| `meta: {institution: X}` | `\meta{institution}{X}` — 要素ごとに1つ、名前は任意 |

重要な区別は、`"[[id]]"` と書いた値は **tree 参照** となり解決が必須である一方、
それ以外は **リテラル** 文字列になる、という点です。

### 昇格キー

以下の名前は `meta` の下に入れ子にせず、トップレベルのキーとして直接書けます。
フロントマターをプロパティ一覧として表示するエディタから直接編集できるようにするためです。

```text
position   institution   venue   source   doi     orcid
external   slides        video   bibtex   author  toc     lang
```

`institution: X` と `meta: { institution: X }` は同一の出力になります。
同じ名前を両方の書き方で与えるとエラー（`TM101`）です。`\meta` 要素は、
どちらの書き方をしたかによらずソース順に出力されます。

**キー集合は閉じています。** 未知のキーは `TM101` となるため、綴り間違いは
黙って出力されるのではなく報告されます。

### アドレスの発番

`id` を書かない tree には `tree-md build` がアドレスを与えます。方式は Forester
自身が文書化している規約 — base-36 の数、ゼロ埋め4桁 — に従い、設定できます。

```toml
[id]
alphabet = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"  # 36進
width    = 4          # 下限の桁数。大きい数は単に桁が伸びる
scheme   = "sequential"   # 複数人で書く forest では "random"
prefix   = ""
```

数字であることの意味は、**何も語らない**ことです。何も語らなければ、tree の
何かが変わっても改名したくなりません。Forester の文書はこう述べています —
アドレスは「タイトルや日付をファイル名に埋め込んだときのように改名したく
ならないように」存在する、と。

人間可読なアドレスも使えます。Forester の文書が名指しする種類 — 書誌参照と
人物 — には向いています。`id` を書けばそのまま残り、**書かれたアドレスが
発番で上書きされることはありません**。

alphabet と prefix は設定読み込み時に検査されるので、識別子として不正な
アドレスを生みうる方式は、ビルドの途中ではなくそこで弾かれます。

### フロントマターと区切り線

フロントマターを持つ文書では、`---` の行は YAML の終了区切りとして消費されるため、
本文中の `---` は区切り線に **なりません**。代わりに `***` または `___` を使ってください。

## 見出しと subtree

| Markdown | Forester 出力 |
| --- | --- |
| **先頭ブロック**としての `# Title` | ルートの `\title{Title}` |
| `##` – `######` | 入れ子の `\subtree{ \title{...} ... }` |
| 見出しの直前の `<!-- subtree: ID -->` または `<!-- id: ID -->` | 名前付き `\subtree[ID]{ ... }` |
| 見出し末尾のアンカー `## Heading ^ID` | 名前付き `\subtree[ID]{ \title{Heading} ... }` |
| `<!-- h3 -->` | レベル 3 の無題な `\subtree{ ... }` |
| `<!-- h3:ID -->` | レベル 3 の無題かつ名前付き `\subtree[ID]{ ... }` |
| `<!-- /h3 -->` | レベル 3 以深の開いている subtree をすべて閉じる |
| H1 がない場合 | `\title` はファイル名の語幹にフォールバック |

見出しレベルは期待どおりに入れ子になります。`##` が subtree を開き、続く
`###` がその内側に入れ子になり、2つ目の `##` が最初のものを閉じて兄弟を開きます。

```markdown
# Root

## Section A

### Subsection of A

## Section B
```

```tree
\title{Root}
\subtree{
\title{Section A}
\subtree{\title{Subsection of A}}
}

\subtree{\title{Section B}}
```

見出しには本文が必要です。また Markdown の見出しは6段までなので、7個以上の
`#` は見出しではなく段落になります。どちらも黙って形が変わるのではなくエラーに
なります。

### 安定した subtree 識別子

ID を持たない `\subtree` はアドレス可能な名前を持ちません。節へリンクするには、
見出しの直前の行にディレクティブコメントを置いて安定 ID を与えます。

```markdown
<!-- subtree: my-sec -->
## Named Section
```

```tree
\subtree[my-sec]{
\title{Named Section}
\p{...本文...}
}
```

文法は `<!-- subtree: ID -->` です。ID は `[A-Za-z0-9][A-Za-z0-9._-]*` に
一致します。ディレクティブの直後は必ず見出しでなければならず、孤立・重複・
不正なディレクティブはエラーです。

### 無題の subtree と、親の本文への復帰

Forester では書けるが Markdown の見出しでは表現できない形が2つあります。
`\title` を持たない subtree と、subtree の後に続きながらなお親に属する内容
です。見出しは必ずタイトルを伴い、必ず同レベル以下の次の見出しまで続くので、
どちらも表現できません。この差を3つのディレクティブが埋めます。

```markdown
# Root

導入。

<!-- h2:aside -->

無題だが、リンクできるよう名前を付けた subtree。

<!-- h3 -->

無題かつ無名で、1段深く入れ子になっている。

<!-- /h2 -->

subtree が終わり、ルートの本文に戻った。
```

```tree
\title{Root}
\p{導入。}

\subtree[aside]{
\p{無題だが、リンクできるよう名前を付けた subtree。}

\subtree{
\p{無題かつ無名で、1段深く入れ子になっている。}
}
}

\p{subtree が終わり、ルートの本文に戻った。}
```

開きディレクティブが自分のレベルを名乗るため、ディレクティブで区切られた
subtree は見出しが作るのと同じレベルスタックにそのまま乗ります。`<!-- h3 -->`
はレベル3以深の開いている subtree を閉じて新しく開く、`###` とまったく同じ
動作です。交差は起こりえず、2つの形式は自由に混在できます。

**閉じディレクティブは任意です。** レベルは同レベル以下の次の見出しまたは
ディレクティブで、そしてファイル終端で、自動的に閉じます。`<!-- /hN -->` を
書くのは、その後に親の本文の続きを書きたいときだけです。見出しが開いた
subtree も閉じられます。

| 規則 | |
| --- | --- |
| レベル | `h2` から `h6`。`h1` は文書のルート |
| 識別子 | 開きは任意、閉じでは指定するとエラー |
| 位置 | 文書レベルのみ。リストや引用の内側は不可 |
| 空 | 内容のない無題 subtree はエラー |
| 閉じ | そのレベルに開いた subtree が無い `<!-- /hN -->` はエラー |

通常のコメントは従来どおり破棄されます。ただし最初の語がこれらのディレクティブ
に*見える*のに解釈できないコメント（`<!-- H3 -->`、`<!-- h7 -->`、
`<!-- /h3:x -->` など）はエラーです。黙って捨てると、何の手がかりもないまま
出力される木の形が変わってしまうためです。

## インライン要素

| Markdown | Forester 出力 |
| --- | --- |
| `**strong**` | `\strong{strong}` |
| `*emphasis*` | `\em{emphasis}` |
| `` `code` `` | `\code{code}` |
| `[label](https://example.test)` | `[label](https://example.test)` — ネイティブ構文をそのまま出力 |
| `<https://example.test>` | ネイティブの自動リンク |
| 行末の半角空白2つ | `\<html:br>{}` |
| 段落内の単一改行 | 半角空白1つ（ソフト改行） |

## ブロック要素

| Markdown | Forester 出力 |
| --- | --- |
| 段落 | `\p{...}` |
| 引用 | `\blockquote{\p{...}}` |
| 箇条書き | `\ul{\li{...}\li{...}}` |
| 1 から始まる番号付きリスト | `\ol{\li{...}\li{...}}` |
| *n*（≠1）から始まる番号付きリスト | `\<html:ol>[start]{n}{\li{...}}` |
| 言語指定なしのコードブロック | `\<html:pre>{\<html:code>{...}}` |
| 言語指定ありのフェンスコード | `\<html:pre>[class]{language-ocaml}{\<html:code>{...}}` |
| `***` / `___` 区切り線 | `\<html:hr>{}` |
| `<!-- comment -->` | 破棄 |

tight なリストと loose なリストは同じ出力になります。この区別は Forester
では表現されません。

## リンク・埋め込み・トランスクルージョン

| Markdown | Forester 出力 | 意味 |
| --- | --- | --- |
| `[[id]]` | `[[id]]` | tree `id` へのリンク |
| `[[id\|alias]]` | `[alias](id)` | リンク文字列を指定したリンク |
| **段落中に単独で置いた** `![[id]]` | `\transclude{id}` | tree 全体をその場に展開 |

`![[id]]` 埋め込みは、それ自身の段落に単独で存在しなければなりません。
他のテキストと混在したり、リストや引用の内側にある埋め込みはエラー（`TM106`）です。
Forester のトランスクルージョンはブロックレベルの操作であり、インラインでの
忠実な表現が存在しないためです。

### 解決は閉世界

`[[target]]` は既知のローカル識別子インデックスに対してのみ解決されます。

- 生成される tree のルート（あなたの `.tree.md` ファイル由来）
- 名前付き subtree（`<!-- subtree: ID -->` と `<!-- hN:ID -->`）
- forest 内の手書き `.tree` ファイルのルート

解決できない対象は `TM202` です。コンパイルが通るリンク切れは存在しません。

### 同一性と、それが由来したファイル

tree の同一性は、`id` が書かれていればそれ、無ければファイル名です。同一性は
どこにも出力されません — 書き出される `.tree` の**ファイル名そのもの**であり、
Forester はそこから同一性を読むためです。`a/note.tree.md` に `id: mlnet-7` と
書けば `a/mlnet-7.tree` が生成され、`mlnet-7` として参照されます。

明示することの意味は、**ファイル名を自由に変えられる**ことです。改題しても
翻訳しても、公開済みのアドレスと既存の参照は動きません。

ファイル名はアドレスではなくなりますが、**検索キーではあり続けます** —
Obsidian が補完し、実際に書くのはファイル名だからです。したがって参照は
ファイル名で書いてよく、同一性に解決されます。

```markdown
[[情報概念]]              →  [[mlnet-7]]
[[情報概念.tree]]         →  [[mlnet-7]]
[[mlnet-7]]               →  [[mlnet-7]]
![[情報概念]]             →  \transclude{mlnet-7}
```

同一性がファイル名より先に試されるため、ある tree の `id` が別の tree の
ファイル名と一致していても、同一性が勝ちます。

### `.tree` サフィックス規則

`.tree` で終わる対象がインデックスに存在しない場合、そのサフィックスを外して
再試行します。ノートをファイル名で参照する Obsidian 形式のエディタは
`notes.tree.md` を `notes.tree` として扱い `![[notes.tree]]` と書きますが、
これは tree `notes` に解決され `\transclude{notes}` として出力されます。
つまり綴りではなく同一性が使われます。

厳密な綴りが先に試されるため、同一性が本当に `notes.tree` である tree が
隠されることはなく、解決不能な `[[missing.tree]]` は依然として `TM202` です。

### subtree アンカー規則

Obsidian は subtree を直接指せません。ノートを指し、その中のブロックに
アンカーを打つことで subtree に到達します。

| Markdown | Forester 出力 |
| --- | --- |
| `![[notes#^aside]]` | `\transclude{aside}` |
| `[[notes#^aside\|その注釈]]` | `[その注釈](aside)` |
| `[[#^aside]]` | `[[aside]]` — 同一ノート内の subtree |
| `A remark. ^aside` | `\p{A remark.}` — アンカーは落とされる |

この綴りにおけるノートはアンカーの在り処を示すだけで、subtree の同一性は
アンカー自身です。したがってそれが解決先となり、出力されるのも同一性であって
綴りではありません。`.tree` サフィックス規則とまったく同じ扱いです。解決後の
id は他の対象と同様に閉世界の検査を通るので、`![[notes#^missing]]` は `TM202`
になります。

`#Heading` は subtree ではなく節を指します。節は見出しに id を与えない限り
Forester 上のアドレスを持たないため、その旨を述べる `TM105` になります。

末尾の `^id` は Obsidian がブロックに印を付ける記法であって本文ではないため、
出力せず取り除きます。数えるのはブロック末尾のトークンのみ、かつ行頭または
空白に続くものだけなので、`the value x^2` のキャレットは残ります。アンカー
だけの段落は `\p{}` を残しません。

## 数式

| Markdown | Forester 出力 |
| --- | --- |
| インラインの `$x^2$` | `#{x^2}` |
| **段落中に単独で置いた** `$$y = mx + b$$` | `##{y = mx + b}` |

埋め込みと同様、ディスプレイ数式もそれ自身の段落に単独で存在する必要があります。
リスト・引用・他のテキストを含む段落の中にあるディスプレイ数式は `TM107` です。
TeX の中身は出力前に波括弧の対応が検査されるため、直列化できない数式は
壊れた `.tree` を生成せずに報告されます。

フェンスによる数式ブロック（` ```math `）は **サポートされません**。

## 画像とアセット

| Markdown | Forester 出力 |
| --- | --- |
| `![External](https://example.test/img.png)` | `\<html:img>[src]{https://example.test/img.png}[alt]{External}{}` |
| `![Plot](images/x.png)` | `\<html:img>[src]{\route-asset{assets/images/x.png}}[alt]{Plot}{}` |

**ローカル**の画像パスは、`forest.toml` の `[forest].assets` で宣言された
アセットルートに対して `\route-asset` 経由でルーティングされます。ファイルは
ちょうど1つのアセットルート配下に実在しなければなりません。存在しない場合は
`TM203`、複数のルートに一致する曖昧な場合は `TM204`、安全でないパス（絶対パス・
外への脱出・隠し要素を含む）は `TM205` です。

## エスケープ

Forester にとって構文的に意味を持つ文字は、リテラルテキスト中に現れた場合
自動的にエスケープされます。

| 文字 | 出力 |
| --- | --- |
| `%` | `\%` |
| `\` `#` `{` `}` `[` `]` `(` `)` | `\verbFMD\|<文字>FMD` |

散文中のリテラルな `#` が出力で `\verbFMD|#FMD` になるのはこのためです。
これは正しく、`#` としてレンダリングされます。

## 拒否される構文

**生の Forester を素通しする抜け道はありません。** 以下は警告ではなくエラーです。

| 拒否される対象 | コード |
| --- | --- |
| 生の HTML（コメントを除くインライン・ブロックとも） | `TM102` |
| GFM のテーブル・タスクリスト・打ち消し線・脚注 | `TM102` |
| フェンス数式ブロック、未対応の Cmarkit 拡張ノード全般 | `TM102` |
| 先頭ブロック以外の位置にある H1、重複する H1 | `TM103` |
| 見出しレベルの飛ばし（`##` から直接 `####`） | `TM103` |
| リスト項目や引用の内側に入れ子になった見出し | `TM103` |
| 本文のない見出し | `TM103` |
| CommonMark が段落として読む7個以上の `#` | `TM103` |
| 不正・重複・孤立した subtree ディレクティブ | `TM104` |
| 文書レベル以外に置かれた subtree ディレクティブ | `TM104` |
| `h2`–`h6` の範囲外の subtree レベル | `TM104` |
| そのレベルに開いた subtree が無い `<!-- /hN -->` | `TM104` |
| 内容のない無題 subtree | `TM104` |
| 不正な Wiki リンク（`[[a\|b\|c]]`、不正な ID、空のエイリアス） | `TM105` |
| リスト・引用の内側、または段落中に混在した埋め込み | `TM106` |
| リスト・引用の内側、または段落中に混在したディスプレイ数式 | `TM107` |

---

## CLI リファレンス

```text
tree-md check [--config PATH]
tree-md build [--config PATH]
```

| コマンド | 挙動 |
| --- | --- |
| `check` | forest 全体を検証し、生成状態の問題を報告する。**ファイルは一切書き込まない**。生成状態がクリーンなときのみ 0 で終了する |
| `build` | まず検証し、その後トランザクショナルに生成物を同期する |

`--config PATH` の既定値は `./tree-md.toml` で、カレントディレクトリから厳密に
読み込みます。**親ディレクトリは探索しません。**

### 終了コード

| コード | 意味 |
| --- | --- |
| `0` | 成功。`check` では生成状態がクリーンであることも確認済み |
| `1` | ソース・意味論・forest 整合性・生成状態の診断 |
| `2` | CLI 用法、設定、不正なマニフェスト／ジャーナル、I/O、内部エラー |

### 環境変数

| 変数 | 効果 |
| --- | --- |
| `TREE_MD_BACKTRACE=1` | 内部エラー時に OCaml のバックトレースを表示する |

## 設定

```toml
version = 1
forest  = "forest.toml"
sources = ["trees-md"]
output  = "generated"
target  = "forester-6.0-dev@30b73641cef02433ee158db6ddc77f7b49de60be"
```

| キー | 意味 |
| --- | --- |
| `version` | 設定スキーマのバージョン。`1` でなければならない |
| `forest` | Forester の `forest.toml` へのパス |
| `sources` | `.tree.md` を探索するソースルート。互いに異なる必要がある |
| `output` | 生成 `.tree` の出力ルート。ソースルートと重なってはならない |
| `target` | 互換性プロファイル。それ以外の値は設定エラー |

すべてのパスは `tree-md.toml` を含むディレクトリからの相対です。参照される
`forest.toml` が `[forest].trees` と `[forest].assets` を供給し、これらは
`forest.toml` を含むディレクトリからの相対です。正規化された出力ルートは
`[forest].trees` に含まれていなければなりません。

## 生成ファイルの安全性

出力ディレクトリはコンパイラの所有物として扱われ、その所有権は前提ではなく
強制されます。

- **マニフェストが所有するファイルのみを管理します。** `build` が作成・置換・
  削除するのは、直前のマニフェスト（`<output>/.tree-md-manifest.json`）に
  記載されたファイルだけです。未知のファイルが削除されることはありません。
  未知のファイルが出力予定のパスを占有している場合は、上書きせずビルドを失敗させます。
- **手動変更を保護します。** 管理下のファイルを置換・削除する前に、`build` は
  現在の SHA-256 をマニフェストと照合します。手で編集された生成ファイルは
  エラーであり、黙って上書きされることはありません。**`--force` は意図的に
  用意していません。**
- **`check` は書き込みません。** ファイルを作らず、ロックも取りません。ロック
  ファイルが存在する場合は読み取り専用で開いて非破壊的に検査します。書き込み中の
  プロセスがある場合は終了コード 2 の並行性エラーです。
- **中断されたビルドはロールフォワードされます。** ステージされたバイト列を
  すべて書き込み flush した後にプリコミットジャーナル
  （`<output>/.tree-md-transaction.json`）を設置します。コミットが中断された後、
  `check` は書き込みを行わずに不完全な状態（`TM305`）を報告し、次の `build` が
  書き込みロックの下でハッシュ検証つきロールフォワードを実行します。
- **耐久性の前提。** クラッシュ保証は、同一ファイルシステム内のアトミックな
  `rename` と `fsync` を尊重するローカルファイルシステム上でのみ成立します。
  これらの意味論を持たないネットワークファイルシステムは、サポートされる
  耐久性モデルの範囲外です。

## 診断

すべての診断は安定したコード、重大度、ソース範囲、抜粋を持ちます。

| 範囲 | 分類 | 終了コード |
| --- | --- | --- |
| `TM0xx` | ソースのエンコーディングとフロントマター構文 | 1 |
| `TM1xx` | 文書の意味論（見出し、ディレクティブ、リンク、配置） | 1 |
| `TM2xx` | forest の整合性（同一性、解決、アセット） | 1 |
| `TM3xx` | 生成状態（欠落、変更、陳腐化、衝突、中断） | 1 |
| `TM4xx` | 設定、マニフェスト、ロック、I/O | 2 |
| `TM500` | 内部エラー | 2 |

<details>
<summary>コード一覧</summary>

| コード | 意味 |
| --- | --- |
| `TM001` | 不正な UTF-8 |
| `TM002` | YAML フロントマターの構文エラー |
| `TM003` | ファイル先頭に UTF-8 BOM がある |
| `TM101` | フロントマターのスキーマエラー（未知のキー、重複、不正な日付） |
| `TM102` | 未対応の Markdown 構文 |
| `TM103` | 見出し構造のエラー |
| `TM104` | subtree ディレクティブのエラー |
| `TM105` | 不正な Wiki リンク／埋め込み |
| `TM106` | 埋め込みの位置が不正 |
| `TM107` | ディスプレイ数式の位置が不正、または直列化できない TeX |
| `TM201` | tree 同一性の重複 |
| `TM202` | 解決できない参照 |
| `TM203` | アセットが存在しない |
| `TM204` | アセットが曖昧（複数のアセットルートに一致） |
| `TM205` | 安全でないアセットパスまたはソースパス |
| `TM301` | 生成物が欠落している |
| `TM302` | 生成物が変更されている（ハッシュ不一致） |
| `TM303` | 生成物が陳腐化している |
| `TM304` | 未知のファイルが出力予定のパスを占有している |
| `TM305` | 中断されたビルドによる不完全なトランザクション |
| `TM306` | 孤立したステージングディレクトリ |
| `TM401` | 設定エラー |
| `TM402` | 不正なマニフェスト |
| `TM403` | トランザクション・ロック・ファイルシステム安全性の失敗 |
| `TM404` | I/O エラー |
| `TM500` | 内部エラー |

</details>

例:

```console
$ tree-md build
TM003: error: file begins with a UTF-8 byte order mark; remove it
  --> trees-md/index.tree.md:1:1
   |
   | ﻿# BOM Title
   | ^
```

## 開発

```bash
dune build              # ビルド
dune runtest            # 18 の Alcotest スイート（444 ケース）+ cram シナリオ
dune pkg lock           # 固定された依存閉包を更新
```

外部 Forester との互換性ジョブは
[`test/forester_compat.sh`](./test/forester_compat.sh) です。バージョンで
ゲートされており、`PATH` 上の任意の Forester ではなく固定ビルドに対して実行されます。

| ドキュメント | 内容 |
| --- | --- |
| [`VERIFICATION.md`](./VERIFICATION.md) | 設計要件とテストの対応表 |
| [`DEPENDENCIES.md`](./DEPENDENCIES.md) | 解決済み依存閉包とライセンス監査 |
| [`CHANGELOG.md`](./CHANGELOG.md) | リリース履歴 |
| [`REFERENCE.md`](./REFERENCE.md) | 上流の参考リンク |

## コントリビューション

Issue と Pull Request は <https://github.com/ryoryoryo3838/tree-md> で歓迎します。

本コンパイラの価値は出力が厳密であることそのものにあるため、出力挙動を変える
変更には必ずテストを追加してください。`test/fixtures/markdown/` と
`test/fixtures/forester/` にゴールデンな入出力のペアがあります。

## ライセンス

[MIT](./LICENSE) © ryoryoryo3838

本リポジトリにサードパーティのソースは同梱しておらず、リンクされる依存関係に
コピーレフト義務を課すものはありません。詳細は
[`DEPENDENCIES.md`](./DEPENDENCIES.md) の監査結果を参照してください。
