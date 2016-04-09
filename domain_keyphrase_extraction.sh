#!/bin/bash

AUTO_LABEL=1
WORDNET_NOUN=1
DATA_LABEL=data/wiki.label.auto
KNOWLEDGE_BASE=data/wiki_labels_quality.txt
KNOWLEDGE_BASE_LARGE=data/wiki_labels_all.txt

STOPWORD_LIST=../src/tools/stopwords.txt
SUPPORT_THRESHOLD=$MIN_PHRASE_SUPPORT
DISCARD_RATIO=0.00
MAX_ITERATION=5

NEED_UNIGRAM=1
ALPHA=0.85

RAW_TEXT2=`readlink -f $RAW_TEXT`

cd SegPhrase
make
# clearance
rm -rf tmp
rm -rf results

mkdir -p tmp
mkdir -p results

# preprocessing
./bin/from_raw_to_binary_text ${RAW_TEXT2} tmp/sentencesWithPunc.buf

# frequent phrase mining for phrase candidates
${PYPY} ./src/frequent_phrase_mining/main.py -thres ${SUPPORT_THRESHOLD} -o ./results/patterns.csv -raw ${RAW_TEXT2}
${PYPY} ./src/preprocessing/compute_idf.py -raw ${RAW_TEXT2} -o results/wordIDF.txt

# feature extraction
./bin/feature_extraction tmp/sentencesWithPunc.buf results/patterns.csv ${STOPWORD_LIST} results/wordIDF.txt results/feature_table_0.csv

if [ ${AUTO_LABEL} -eq 1 ];
then
    ${PYTHON} src/classification/auto_label_generation.py ${KNOWLEDGE_BASE} ${KNOWLEDGE_BASE_LARGE} results/feature_table_0.csv results/patterns.csv ${DATA_LABEL}
fi

# classifier training
./bin/predict_quality results/feature_table_0.csv ${DATA_LABEL} results/ranking.csv outsideSentence,log_occur_feature,constant,frequency 0 TRAIN results/random_forest_0.model

MAX_ITERATION_1=$(expr $MAX_ITERATION + 1)

# 1-st round
./bin/from_raw_to_binary ${RAW_TEXT2} tmp/sentences.buf
./bin/adjust_probability tmp/sentences.buf ${OMP_NUM_THREADS} results/ranking.csv results/patterns.csv ${DISCARD_RATIO} ${MAX_ITERATION} ./results/ ${DATA_LABEL} ./results/penalty.1

# 2-nd round
./bin/recompute_features results/iter${MAX_ITERATION_1}_discard${DISCARD_RATIO}/length results/feature_table_0.csv results/patterns.csv tmp/sentencesWithPunc.buf results/feature_table_1.csv ./results/penalty.1 1
./bin/predict_quality results/feature_table_1.csv ${DATA_LABEL} results/ranking_1.csv outsideSentence,log_occur_feature,constant,frequency 0 TRAIN results/random_forest_1.model
./bin/adjust_probability tmp/sentences.buf ${OMP_NUM_THREADS} results/ranking_1.csv results/patterns.csv ${DISCARD_RATIO} ${MAX_ITERATION} ./results/1. ${DATA_LABEL} ./results/penalty.2

# phrase list & segmentation model
./bin/build_model results/1.iter${MAX_ITERATION_1}_discard${DISCARD_RATIO}/ 6 ./results/penalty.2 results/segmentation.model

# unigrams
normalize_text() {
  awk '{print tolower($0);}' | sed -e "s/’/'/g" -e "s/′/'/g" -e "s/''/ /g" -e "s/'/ ' /g" -e "s/“/\"/g" -e "s/”/\"/g" \
  -e 's/"/ " /g' -e 's/\./ \. /g' -e 's/<br \/>/ /g' -e 's/, / , /g' -e 's/(/ ( /g' -e 's/)/ ) /g' -e 's/\!/ \! /g' \
  -e 's/\?/ \? /g' -e 's/\;/ /g' -e 's/\:/ /g' -e 's/-/ - /g' -e 's/=/ /g' -e 's/=/ /g' -e 's/*/ /g' -e 's/|/ /g' \
  -e 's/«/ /g' | tr 0-9 " "
}
normalize_text < results/1.iter${MAX_ITERATION}_discard${DISCARD_RATIO}/segmented.txt > tmp/normalized.txt

cd word2vec_tool
make
cd ..
./word2vec_tool/word2vec -train tmp/normalized.txt -output ./results/vectors.bin -cbow 2 -size 300 -window 6 -negative 25 -hs 0 -sample 1e-4 -threads ${OMP_NUM_THREADS} -binary 1 -iter 15
time ./bin/generateNN results/vectors.bin results/1.iter${MAX_ITERATION_1}_discard${DISCARD_RATIO}/ 30 3 results/u2p_nn.txt results/w2w_nn.txt
./bin/qualify_unigrams results/vectors.bin results/1.iter${MAX_ITERATION_1}_discard${DISCARD_RATIO}/ results/u2p_nn.txt results/w2w_nn.txt ${ALPHA} results/unified.csv 100 ${STOPWORD_LIST}

${PYPY} src/postprocessing/filter_by_support.py results/unified.csv results/1.iter${MAX_ITERATION}_discard${DISCARD_RATIO}/segmented.txt ${SUPPORT_THRESHOLD} results/salient.csv

if [ ${WORDNET_NOUN} -eq 1 ];
then
    ${PYPY} src/postprocessing/clean_list_with_wordnet.py -input results/salient.csv -output results/salient.csv
fi

cd ..

