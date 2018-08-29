
from glob import glob
BINNING_CONTIGS= "{sample}/{sample}_contigs.fasta"


rule bam_2_sam_binning:
    input:
        "{sample}/sequence_alignment/{sample_reads}.bam"
    output:
        temp("{sample}/sequence_alignment/binning_{sample_reads}.sam")
    threads:
        config['threads']
    resources:
        mem = config["java_mem"],
        java_mem = int(config["java_mem"] * JAVA_MEM_FRACTION)
    shadow:
        "shallow"
    conda:
        "%s/required_packages.yaml" % CONDAENV
    shell:
        """
        reformat.sh in={input} out={output} sam=1.3
        """




rule pileup_for_binning:
    input:
        fasta = BINNING_CONTIGS,
        sam = "{sample}/sequence_alignment/binning_{sample_reads}.sam",
    output:
        covstats = "{sample}/binning/coverage/{sample_reads}_coverage_stats.txt",
    params:
        pileup_secondary = 't' if config.get("count_multi_mapped_reads", CONTIG_COUNT_MULTI_MAPPED_READS) else 'f',
    log:
        "{sample}/logs/binning/calculate_coverage/pileup_reads_from_{sample_reads}_to_filtered_contigs.log" # this file is udes for assembly report
    conda:
        "%s/required_packages.yaml" % CONDAENV
    threads:
        config.get("threads", 1)
    resources:
        mem = config.get("java_mem", JAVA_MEM),
        java_mem = int(config.get("java_mem", JAVA_MEM) * JAVA_MEM_FRACTION)
    shell:
        """pileup.sh ref={input.fasta} in={input.sam} \
               threads={threads} \
               -Xmx{resources.java_mem}G \
               covstats={output.covstats} \
               secondary={params.pileup_secondary} \
                2> {log}
        """




localrules: get_contig_coverage_from_bb, combine_coverages
rule get_contig_coverage_from_bb:
    input:
        coverage = "{sample}/binning/coverage/{sample_reads}_coverage_stats.txt"
    output:
        temp("{sample}/binning/coverage/{sample_reads}_coverage.txt"),
    run:
        with open(input[0]) as fi, open(output[0], "w") as fo:
            # header
            next(fi)
            for line in fi:
                toks = line.strip().split("\t")
                print(toks[0], toks[1], sep="\t", file=fo)


rule combine_coverages:
    input:
        covstats = lambda wc: expand("{sample}/binning/coverage/{sample_reads}_coverage_stats.txt",
                                 sample_reads = GROUPS[config['samples'][wc.sample]['group']],
                                 sample=wc.sample)
    output:
        "{sample}/binning/coverage/combined_coverage.tsv"
    run:

        import pandas as pd
        import os

        combined_cov={}
        for cov_file in input:

            sample= os.path.split(cov_file)[-1].split('_')[0]
            data= pd.read_table(cov_file,index_col=0)

            data.loc[data.Avg_fold<0,'Avg_fold']=0
            combined_cov[sample]= data.Avg_fold
        pd.DataFrame(combined_cov).to_csv(output[0],sep='\t')



## CONCOCT
rule run_concoct:
    input:
        coverage = "{sample}/binning/coverage/combined_coverage.tsv",
        fasta = BINNING_CONTIGS
    output:
        "{{sample}}/binning/concoct/intermediate_files/clustering_gt{}.csv".format(config['concoct']["min_contig_length"])
    params:
        basename= lambda wc, output: os.path.dirname(output[0]),
        Nexpected_clusters= config['concoct']['Nexpected_clusters'],
        read_length= config['concoct']['read_length'],
        min_length=config['concoct']["min_contig_length"],
        niterations=config["concoct"]["Niterations"]
    log:
        "{sample}/binning/concoct/intermediate_files/log.txt"
    conda:
        "%s/concoct.yaml" % CONDAENV
    threads:
        10 # concoct uses 10 threads by default, wit for update: https://github.com/BinPro/CONCOCT/issues/177
    resources:
        mem = config["java_mem"]
    shell:
        """
        concoct -c {params.Nexpected_clusters} \
            --coverage_file {input.coverage} \
            --composition_file {input.fasta} \
            --basename {params.basename} \
            --read_length {params.read_length} \
            --length_threshold {params.min_length} \
            --converge_out \
            --iterations {params.niterations}
        """


localrules: convert_concoct_csv_to_tsv
rule convert_concoct_csv_to_tsv:
    input:
        rules.run_concoct.output[0]
    output:
        temp("{sample}/binning/concoct/cluster_attribution.tmp")
    run:
        with open(input[0]) as fin, open(output[0],'w') as fout:
            for line in fin:
                fout.write(line.replace(',','\t'))


## METABAT
rule get_metabat_depth_file:
    input:
        bam = lambda wc: expand("{sample}/sequence_alignment/{sample_reads}.bam",
                     sample_reads = GROUPS[config['samples'][wc.sample]['group']],
                     sample=wc.sample)
    output:
        temp("{sample}/binning/metabat/metabat_depth.txt")
    log:
        "{sample}/binning/metabat/metabat.log"
    conda:
        "%s/metabat.yaml" % CONDAENV
    threads:
        config['threads']
    resources:
        mem = config["java_mem"]
    shell:
        """
        jgi_summarize_bam_contig_depths --outputDepth {output} {input.bam} \
            &> >(tee {log})
        """


rule metabat:
    input:
        depth_file = rules.get_metabat_depth_file.output,
        contigs = BINNING_CONTIGS
    output:
        temp("{sample}/binning/metabat/cluster_attribution.tmp"),
    params:
          sensitivity = 500 if config['metabat']['sensitivity'] == 'sensitive' else 200,
          min_contig_len = config['metabat']["min_contig_length"],
          output_prefix = "{sample}/binning/bins/bin"
    benchmark:
        "logs/benchmarks/binning/metabat/{sample}.txt"
    log:
        "{sample}/logs/binning/metabat.txt"
    conda:
        "%s/metabat.yaml" % CONDAENV
    threads:
        config["threads"]
    resources:
        mem = config["java_mem"]
    shell:
        """
        metabat2 -i {input.contigs} \
            --abdFile {input.depth_file} \
            --minContig {params.min_contig_len} \
            --numThreads {threads} \
            --maxEdges {params.sensitivity} \
            --saveCls --noBinOut \
            -o {output} \
            &> >(tee {log})
        """





rule maxbin:
    input:
        fasta = BINNING_CONTIGS,
        abund = "{sample}/binning/coverage/{sample}_coverage.txt",

    output:
        directory("{sample}/binning/maxbin/intermediate_files")
    params:
        mi = config["maxbin"]["max_iteration"],
        mcl = config["maxbin"]["min_contig_length"],
        pt = config["maxbin"]["prob_threshold"],
        output_prefix = lambda wc, output: os.path.join(output[0], wc.sample)
    log:
        "{sample}/logs/binning/maxbin.log"
    conda:
        "%s/maxbin.yaml" % CONDAENV
    threads:
        config["threads"]
    shell:
        """
        mkdir {output[0]} 2> {log}
        run_MaxBin.pl -contig {input.fasta} \
            -abund {input.abund} \
            -out {params.output_prefix} \
            -min_contig_length {params.mcl} \
            -thread {threads} \
            -prob_threshold {params.pt} \
            -max_iteration {params.mi} >> {log}

        mv {params.output_prefix}.summary {output[0]}/.. 2>> {log}
        mv {params.output_prefix}.marker {output[0]}/..  2>> {log}
        mv {params.output_prefix}.marker_of_each_bin.tar.gz {output[0]}/..  2>> {log}
        mv {params.output_prefix}.log {output[0]}/..  2>> {log}

        """





localrules: get_unique_cluster_attribution, get_maxbin_cluster_attribution, get_bins

rule get_unique_cluster_attribution:
    input:
        "{sample}/binning/{binner}/cluster_attribution.tmp"
    output:
        "{sample}/binning/{binner}/cluster_attribution.tsv"
    run:
        import pandas as pd
        import numpy as np


        d= pd.read_table(input[0],index_col=0, squeeze=True, header=None)

        assert type(d) == pd.Series, "expect the input to be a two column file: {}".format(input[0])

        old_cluster_ids = list(d.unique())
        if 0 in old_cluster_ids:
            old_cluster_ids.remove(0)
        N_clusters= len(old_cluster_ids)

        float_format= "{sample}.{binner}.{{:0{N_zeros}d}}".format(N_zeros=len(str(N_clusters)), **wildcards)

        map_cluster_ids = pd.Series(np.arange(N_clusters)+1,index= old_cluster_ids )
        map_cluster_ids= map_cluster_ids.apply(float_format.format)

        new_d= d.map(map_cluster_ids)

        new_d.to_csv(ouput[0],sep='\t')


rule get_maxbin_cluster_attribution:
    input:
        directory("{sample}/binning/maxbin/intermediate_files")
    output:
        "{sample}/binning/maxbin/cluster_attribution.tsv"
    params:
        file_name = lambda wc, input: "{folder}/{sample}.{{binid}}.fasta".format(folder=input[0], **wc)
    run:
        bin_ids, = glob_wildcards(params.file_name)
        print("found {} bins".format(len(bin_ids)))
        with open(output[0],'w') as out_file:
            for binid in bin_ids:
                with open(params.file_name.format(binid=binid)) as bin_file:
                    for line in bin_file:
                        if line.startswith(">"):
                            fasta_header = line[1:].strip().split()[0]
                            out_file.write("{fasta_header}\t{sample}.maxbin.{binid}\n".format(binid=binid,
                                                                                              fasta_header=fasta_header,
                                                                                              sample=wildcards.sample))
                os.remove(params.file_name.format(binid=binid))


rule get_bins:
    input:
        cluster_attribution = "{sample}/binning/{binner}/cluster_attribution.tsv",
        contigs= BINNING_CONTIGS
    output:
        temp(directory("{sample}/binning/{binner}/bins"))
    params:
        prefix= lambda wc, output: os.path.join(output[0],wc.sample)
    conda:
        "%s/sequence_utils.yaml" % CONDAENV
    script:
        "get_fasta_of_bins.py"

## Checkm
# TODO generalize checkm rules
rule initialize_checkm:
    # input:
    output:
        touched_output = "logs/checkm_init.txt"
    params:
        database_dir = CHECKMDIR,
        script_dir = os.path.dirname(os.path.abspath(workflow.snakefile))
    conda:
        "%s/checkm.yaml" % CONDAENV
    log:
        "logs/initialize_checkm.log"
    shell:
        """
        python {params.script_dir}/rules/initialize_checkm.py \
            {params.database_dir} \
            {output.touched_output} \
            {log}
        """


rule run_checkm_lineage_wf:
    input:
        touched_output = "logs/checkm_init.txt",
        bins = directory("{sample}/binning/{binner}/bins") # actualy path to fastas
    output:
        "{sample}/binning/{binner}/checkm/completeness.tsv"
    params:
        output_dir = lambda wc, output: os.path.dirname(output[0])
    conda:
        "%s/checkm.yaml" % CONDAENV
    threads:
        config.get("threads", 1)
    shell:
        """
        rm -r {params.output_dir}
        checkm lineage_wf \
            --file {params.output_dir}/completeness.tsv \
            --tab_table \
            --quiet \
            --extension fasta \
            --threads {threads} \
            {input.bins} \
            {params.output_dir}
        """



rule run_checkm_tree_qa:
    input:
        tree="{checkmfolder}/completeness.tsv"
    output:
        netwick="{checkmfolder}/tree.nwk",
        summary="{checkmfolder}/taxonomy.tsv",
    params:
        tree_dir = lambda wc, input: os.path.dirname(input.tree),
    conda:
        "%s/checkm.yaml"  % CONDAENV
    threads:
        1
    shell:
        """
            checkm tree_qa \
               {params.tree_dir} \
               --out_format 4 \
               --file {output.netwick}

               checkm tree_qa \
                  {params.tree_dir} \
                  --out_format 2 \
                  --file {output.summary}\
                  --tab_table

        """


rule checkm_tetra:
    input:
        contigs=BINNING_CONTIGS,
    output:
        "{sample}/binning/{binner}/checkm/tetranucleotides.txt"
    log:
        "{sample}/logs/binning/{binner}/checkm/tetra.txt"
    conda:
        "%s/checkm.yaml" % CONDAENV
    threads:
        config.get("threads", 8)
    shell:
        """
            checkm tetra \
            --threads {threads} \
            {input.contigs} {output} 2> {log}
        """


rule checkm_outliers:
    input:
        tetra= "{sample}/binning/{binner}/checkm/tetranucleotides.txt",
        bin_folder= directory("{sample}/binning/{binner}/bins"),
        checkm = "{sample}/binning/{binner}/checkm/completeness.tsv"
    params:
        checkm_folder = lambda wc, input: os.path.dirname(input.checkm),
        report_type = 'any',
        treshold = 95 #reference distribution used to identify outliers; integer between 0 and 100 (default: 95)
    output:
        "{sample}/binning/{binner}/checkm/outliers.txt"
    log:
        "{sample}/logs/binning/{binner}/checkm/outliers.txt"
    conda:
        "%s/checkm.yaml" % CONDAENV
    threads:
        config.get("threads", 8)
    shell:
        """
            checkm outliers \
            --extension fasta \
            --distributions {params.treshold} \
            --report_type {params.report_type} \
            {params.checkm_folder} \
            {input.bin_folder} \
            {input.tetra} \
            {output} 2> {log}
        """


rule find_16S:
    input:
        contigs=BINNING_CONTIGS,
        bin_dir= directory("{sample}/binning/{binner}/bins")
    output:
        "{sample}/binning/{binner}/checkm/SSU/ssu_summary.tsv",
    params:
        output_dir = lambda wc, output: os.path.dirname(output[0]),
        evalue = 1e-05,
        concatenate = 200 #concatenate hits that are within the specified number of base pairs
    conda:
        "%s/checkm.yaml" % CONDAENV
    threads:
        1
    shell:
        """
        rm -r {params.output_dir} && \
           checkm ssu_finder \
               --extension fasta \
               --threads {threads} \
               --evalue {params.evalue} \
               --concatenate {params.concatenate} \
               {input.contigs} \
               {input.bin_dir} \
               {params.output_dir}
        """


rule get_all_16S:
    input:
        expand(rules.find_16S.output,sample=SAMPLES,binner=config['binner'])



rule build_bin_report:
    input:
        completeness_files = expand("{sample}/binning/{{binner}}/checkm/completeness.tsv", sample=SAMPLES),
        taxonomy_files = expand("{sample}/binning/{{binner}}/checkm/taxonomy.tsv", sample=SAMPLES)
    output:
        report = "reports/bin_report_{binner}.html",
        bin_table = "reports/genomic_bins_{binner}.tsv"
    params:
        samples = " ".join(SAMPLES),
        script_dir = os.path.dirname(os.path.abspath(workflow.snakefile))
    conda:
        "%s/report.yaml" % CONDAENV
    shell:
        """
        python {params.script_dir}/report/bin_report.py \
            --samples {params.samples} \
            --completeness {input.completeness_files} \
            --taxonomy {input.taxonomy_files} \
            --report-out {output.report} \
            --bin-table {output.bin_table}
        """



# not working correctly https://github.com/cmks/DAS_Tool/issues/13
rule run_das_tool:
    input:
        cluster_attribution = expand("{{sample}}/binning/{binner}/cluster_attribution.tsv",
            binner=config['binner']),
        contigs = BINNING_CONTIGS,
        proteins= "{sample}/annotation/predicted_genes/{sample}.faa"
    output:
        expand("{{sample}}/binning/DASTool/{{sample}}{postfix}",
               postfix=["_DASTool_summary.txt", "_DASTool_hqBins.pdf", "_DASTool_scores.pdf"]),
        expand("{{sample}}/binning/DASTool/{{sample}}_{binner}.eval",
               binner= config['binner']),
        cluster_attribution = "{sample}/binning/DASTool/cluster_attribution.tsv"
    threads:
        config['threads']
    log:
        "{sample}/logs/binning/DASTool.log"
    conda:
        "%s/DASTool.yaml" % CONDAENV
    params:
        binner_names = ",".join(config['binner']),
        scaffolds2bin = lambda wc, input: ",".join(input.cluster_attribution),
        output_prefix = "{sample}/binning/DASTool/{sample}",
        score_threshold = config['DASTool']['score_threshold'],
        megabin_penalty = config['DASTool']['megabin_penalty'],
        duplicate_penalty = config['DASTool']['duplicate_penalty']
    shell:
        " DAS_Tool --outputbasename {params.output_prefix} "
        " --bins {params.scaffolds2bin} "
        " --labels {params.binner_names} "
        " --contigs {input.contigs} "
        " --search_engine diamond "
        " --proteins {input.proteins} "
        " --write_bin_evals 1 "
        " --create_plots 1 --write_bin_evals 1 "
        " --megabin_penalty {params.megabin_penalty}"
        " --duplicate_penalty {params.duplicate_penalty} "
        " --threads {threads} "
        " --debug "
        " --score_threshold {params.score_threshold} &> >(tee {log}) "
        " ; mv {params.output_prefix}_DASTool_scaffolds2bin.txt {output.cluster_attribution} &> >(tee -a {log})"


# unknown bins and contigs

rule get_unknown_bins:
    input:
        expand("{{sample}}/binning/DASTool/{{sample}}_{binner}.eval", binner= config['binner']),
        expand(directory("{{sample}}/binning/{binner}/bins"), binner= config['binner']),
    output:
        dir= directory("{sample}/binning/Unknown/bins"),
        scores= "{sample}/binning/Unknown/scores.tsv"

    run:
        import pandas as pd
        import shutil

        Scores= pd.DataFrame()

        for (score_file,bin_dir) in zip(input):
            S = pd.read_table(score_file,index=0)

            S= S.loc[S.SCG_Completeness==0]
            Scores= Scores.append(S)

            for bin_id in S.index:
                shutil.copy(os.path.join(bin_dir,bin_id+'.fasta'), ouput.dir )

        Scores.to_csv(output.scores,sep='\t')





## dRep

rule get_all_bins:
    input:
        expand(directory("{sample}/binning/{binner}/bins"),
               sample= SAMPLES, binner= config['final_binner'])
    output:
        directory("genomes/all_bins")
    run:
        os.mkdir(output[0])
        from glob import glob
        import shutil
        for bin_folder in input:
            for fasta_file in glob(bin_folder+'/*.fasta'):

                #fasta_file_name = os.path.split(fasta_file)[-1]
                #in_path = os.path.dirname(fasta_file)
                #out_path= os.path.join(output[0],fasta_file_name)
                #os.symlink(os.path.relpath(fasta_file,output[0]),out_path)

                shutil.copy(fasta_file,output[0])

rule get_quality_for_dRep:
    input:
        "reports/genomic_bins_{binner}.tsv".format(binner=config['final_binner'])
    output:
        temp("genomes/quality.csv")
    run:
        import pandas as pd

        D= pd.read_table(input[0],index_col=0)

        D.index+=".fasta"
        D.index.name="genome"
        D.columns= D.columns.str.lower()
        D.iloc[:,:3].to_csv(ouput[0])


rule first_dereplication:
    input:
        directory("genomes/all_bins"),
        quality= rules.get_quality_for_dRep.output
    output:
        directory("genomes/Dereplication_1/dereplicated_genomes")
    threads:
        config['threads']
    log:
        "logs/genomes/dereplication_1.log"
    conda:
        "%s/dRep.yaml" % CONDAENV
    params:
        filter_length= config['genome_dereplication']['filter']['length'],
        filter_completeness= config['genome_dereplication']['filter']['completeness'],
        filter_contamination= config['genome_dereplication']['filter']['contamination'],
        ANI= config['genome_dereplication']['ANI'],
        completeness_weight= config['genome_dereplication']['weight']['completeness'] ,
        contamination_weight=config['genome_dereplication']['weight']['contamination'] ,
        strain_heterogeneity_weight= config['genome_dereplication']['weight']['completeness'] , #not in table
        N50_weight=config['genome_dereplication']['weight']['N50'] ,
        size_weight=config['genome_dereplication']['weight']['size'] ,
        opt_parameters = config['genome_dereplication']['opt_parameters'],
        work_directory= lambda wc,output: os.path.dirname(output[0]),
        sketch_size= config['genome_dereplication']['sketch_size']

    shell:
        " dRep dereplicate "
        " --genomes {input[0]}/*.fasta "
        " --genomeInfo {input.quality} "
        " --length {params.filter_length} "
        " --completeness {params.filter_completeness} "
        " --contamination {params.filter_contamination} "
        " --SkipSecondary "
        " --P_ani {params.ANI} "
        " --completeness_weight {params.completeness_weight} "
        " --contamination_weight {params.contamination_weight} "
        " --strain_heterogeneity_weight {params.strain_heterogeneity_weight} "
        " --N50_weight {params.N50_weight} "
        " --size_weight {params.size_weight} "
        " --MASH_sketch {params.sketch_size} "
        " --processors {threads} "
        " {params.opt_parameters} "
        " {params.work_directory} "


rule second_dereplication:
    input:
        rules.first_dereplication.output,
        quality= rules.get_quality_for_dRep.output
    output:
        directory("genomes/Dereplication_2/dereplicated_genomes")
    threads:
        config['threads']
    log:
        "logs/genomes/dereplication_2.log"
    conda:
        "%s/dRep.yaml" % CONDAENV
    params:
        ANI= config['genome_dereplication']['ANI'],
        completeness_weight= config['genome_dereplication']['weight']['completeness'] ,
        contamination_weight=config['genome_dereplication']['weight']['contamination'] ,
        strain_heterogeneity_weight= config['genome_dereplication']['weight']['completeness'] , #not in table
        N50_weight=config['genome_dereplication']['weight']['N50'] ,
        size_weight=config['genome_dereplication']['weight']['size'] ,
        opt_parameters = config['genome_dereplication']['opt_parameters'],
        work_directory= lambda wc,output: os.path.dirname(output[0]),
        sketch_size= config['genome_dereplication']['sketch_size']

    shell:
        " dRep dereplicate "
        " --genomes {input[0]}/*.fasta "
        " --genomeInfo {input.quality} "
        " --noQualityFiltering "
        " --S_ani {params.ANI} "
        " --completeness_weight {params.completeness_weight} "
        " --contamination_weight {params.contamination_weight} "
        " --strain_heterogeneity_weight {params.strain_heterogeneity_weight} "
        " --N50_weight {params.N50_weight} "
        " --size_weight {params.size_weight} "
        " --MASH_sketch {params.sketch_size} "
        " --processors {threads} "
        " {params.opt_parameters} "
        " {params.work_directory} "
