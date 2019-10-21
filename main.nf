#!/usr/bin/env nextflow

// DSL 2 syntax
nextflow.preview.dsl=2

// help message
params.help = false
def helpMessage() {
    log.info"""
    ###############################################################################

          +++++++++++++++++'++++
          ++++++++++++++++''+'''
          ++++++++++++++'''''''+
          ++++++++++++++''+'++++
          ++++++++++++++''''++++
          +++++++++++++'++''++++
          ++++++++++++++++++++++       ++++++++:,   +++   ++++++++
          +++++++++++++, +++++++     +++.  .'+++;  +++  :+++   '++
          ++++++ ``'+`  ++++++++   +++'        ';  +++  +++      +
          ++++`   +++  +++++++++  +++              +++  +++:
          ++,  ,+++`  ++++++++++  ++;              +++    ++++
          +, ;+++  + .++++++++++  +++     .++++++  +++       ++++
          + `++;  ++  +++++;;+++  +++         +++  +++          '++,
          + :;   +++, ;++; ;++++  ;++;        +++  +++           +++
          +: ,+++++++;,;++++++++   `+++;      +++  +++  +.      ;++,
          ++++++++++++++++++++++      ++++++++++   +++   ++++++++.
    ===============================================================================
        CSB5 Shotgun Metagenomics Pipeline [version ${params.pipelineVersion}]

    Usage:
    The typical command for running the pipeline is as follows:
      nextflow run ${workflow.projectDir}/main.nf  --read_path PATH_TO_READS

    Input arguments:
      --read_path               Path to a folder containing all input fastq files (this will be recursively searched for *fastq.gz/*fq.gz/*fq/*fastq files) [Default: ${workflow.projectDir}/data]

    Output arguments:
      --outdir                  Output directory [Default: ./pipeline_output/]

    Decontamination arguments:
      --decont_ref_path         Path to the host reference database
      --decont_index            BWA index prefix for the host

    Profiler configuration:
      --profilers               Metagenomics profilers to run [Default: kraken2,metaphlan2]

    Kraken2 arguments:
      --kraken2_index           Path to the kraken2 database

    MetaPhlAn2 arguments:
      --metaphlan2_ref_path     Path to the metaphlan2 database
      --metaphlan2_index        Bowtie2 index prefix for the marker genes [Default: mpa_v20_m200]
      --metaphlan2_pkl          Python pickle file for marker genes [mpa_v20_m200.pkl]

    AWSBatch options:
      --awsqueue                The AWSBatch JobQueue that needs to be set when running on AWSBatch
      --awsregion               The AWS Region for your AWS Batch job to run on
    ###############################################################################
    """.stripIndent()
}
if (params.help){
    helpMessage()
    exit 0
}


// AWSBatch sanity checking
if(workflow.profile.contains('awsbatch')){
    if (!params.containsKey('awsqueue') || !params.containsKey('awsregion')) exit 1, "Specify correct --awsqueue and --awsregion parameters on AWSBatch!"
    //if (!params.outdir.startsWith('s3')) exit 1, "Specify S3 URLs for outdir parameters on AWSBatch!"
}

// Nextflow version sanity checking
if( ! nextflow.version.matches(">= $params.nf_required_version") ){
    exit 1, "[Pipeline error] Nextflow version $params.nf_required_version required! You are running v$workflow.nextflow.version!\n" 
}

// Profiler sanity checking
def profilers = [] as Set
if(params.profilers.getClass() != Boolean){
    def profilers_input = params.profilers.split(',') as Set
    def profilers_expected = ['kraken2', 'metaphlan2'] as Set
    def profiler_diff = profilers_input - profilers_expected
    profilers = profilers_input.intersect(profilers_expected)
    if( profiler_diff.size() != 0 ) {
    	log.warn "[Pipeline warning] Profiler $profiler_diff is not supported yet! Will only run $profilers.\n"
    }
}

// *Decont specific (remove if you don't need decont)* //
if (!params.containsKey('decont_refpath') | !params.containsKey('decont_index')){
    exit 1, "[Pipeline error] Please provide the BWA index path for the host using `--decont_refpath` and `--decont_index`!\n"
}
ch_bwa_idx = file(params.decont_refpath)

// *Kraken2 specific* //
if (profilers.contains('kraken2')){
   if (!params.containsKey('kraken2_index')){
       exit 1, "[Pipeline error] Please provide the Kraken2 index path using `--kraken2_index`!\n"
   }
   ch_kraken_idx = file(params.kraken2_index)
}

// *MetaPhlAn2 specific* //
if (profilers.contains('metaphlan2')){
   if (!params.containsKey('metaphlan2_index') | !params.containsKey('metaphlan2_refpath') | !params.containsKey('metaphlan2_pkl')){
       exit 1, "[Pipeline error] Please provide the metaphlan2 index path using `--metaphlan2_refpath`, `--metaphlan2_pkl` and `--metaphlan2_index`!\n"
   }
   ch_metaphlan2_idx = file(params.metaphlan2_refpath)
}

// *HUMAnN2 specific (remove if you don't need HUMAnN2)* //
// TODO

if (workflow.profile.contains('gis') && !workflow.profile.contains('test')) {
    // Use GIS sample specific pattern
    // Assumes each sample is put into a folder named after the sample name
    // Example1: Sample_MBE032/MBE032_HS007-PE-R00399_L002_R{1,2}_unaligned_001.fastq.gz
    // Example2: MBS667/MBS667-TCAGATGC_S20_L002_R{1,2}_001.fastq.gz
    // TODO: handle multiple fastq files belonging to the same sample. Currently manually concatenating them is a solution.
    ch_reads = Channel
        .fromFilePairs([params.read_path + '/**{R,.,_}{1,2}*f*q*'], flat: true, checkIfExists: true) { file -> file.getParent().name.replaceAll(/Sample_/, '')  }
}
else {
    ch_reads = Channel
        .fromFilePairs([params.read_path + '/**{R,.,_}{1,2}*f*q*'], flat: true, checkIfExists: true) {file -> file.name.replaceAll(/[-_].*/, '')}
}

// import modules
include './modules/decont' params(index: "$params.decont_index", outdir: "$params.outdir")
include './modules/profilers_kraken2_bracken' params(outdir: "$params.outdir")
include './modules/profilers_metaphlan2' params(outdir: "$params.outdir")
// TODO: is there any elegant method to do this?
include SPLIT_PROFILE as SPLIT_METAPHLAN2 from './modules/split_tax_profile' params(outdir: "$params.outdir")
include SPLIT_PROFILE as SPLIT_KRAKEN2 from './modules/split_tax_profile' params(outdir: "$params.outdir")
   

// processes
workflow{
    DECONT(ch_bwa_idx, ch_reads)

    if(profilers.contains('kraken2')){
        KRAKEN2(ch_kraken_idx, DECONT.out[0])
    	BRACKEN(ch_kraken_idx, KRAKEN2.out[1], Channel.from('s', 'g'))
    	SPLIT_KRAKEN2(KRAKEN2.out[0])
    }
    if(profilers.contains('metaphlan2')){
    	METAPHLAN2(ch_metaphlan2_idx, DECONT.out[0])
    	SPLIT_METAPHLAN2(METAPHLAN2.out[0])
    }
}
