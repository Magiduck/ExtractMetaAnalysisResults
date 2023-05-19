#!/bin/bash nextflow

process ExtractSignificantResults {
    scratch true

    input:
        path input
        val genes
        val p_value

    output:
        path "loci.out.csv"

    shell:
        gene_arg = genes.join(" ")
        phenotypes_formatted = genes.collect { "phenotype=$it" }.join("\n")
        '''
        mkdir tmp_eqtls
        echo "!{phenotypes_formatted}" > file_matches.txt

        while read gene; do
          cp -r "!{input}/${gene}" tmp_eqtls/
        done <file_matches.txt

        extract_parquet_results.py \
            --input-file tmp_eqtls \
            --genes !{gene_arg} \
            --p-thresh !{p_value} \
            --cols "+p_value" \
            --output-prefix loci

        rm -r tmp_eqtls
        '''
}

process AnnotateResults {
    input:
        path significantResults
        path variantReference
        path geneReference

    output:
        path "loci.variants.bed"

    script:
        """
        eqtls_to_bed.py \
            --input-file ${significantResults} \
            --variant-reference ${variantReference} \
            --gene-ggf ${geneReference} \
            --out-prefix "loci"
        """
}

process IntersectLoci {
    input:
        path variantLoci
        val variantFlankSize
        path bedFile
        path genomeRef
        path cisTransGenes

    output:
        path "merged.bed"

    script:
        // Define background bed file to take into account
        def bed = bedFile.name != 'NO_FILE' ? "$bedFile" : ''

        // Calculate flanks for genes, calculate flanks for snps, calculate union.
        """
        grep -F -f ${cisTransGenes} "${variantLoci}" > "filtered_variant_loci.bed"

        bedtools slop -i "filtered_variant_loci.bed" -g "${genomeRef}" -b "${variantFlankSize}" > "variant_loci.flank.bed"

        cat "variant_loci.flank.bed" ${bed} > "total.flank.bed"

        # Get the union of the two bed files (including flanks)
        bedtools sort -i "total.flank.bed" > "total.flank.sorted.bed"
        bedtools merge -i "total.flank.sorted.bed" -d 0 -c 4 -o distinct > "merged.bed"
        """
}

process SelectFollowUpLoci {
    input:
        path variantBed
        val variantFlankSize
        path genomeRef
        val genes

    output:
        path "cis_trans_intersection.bed"

    shell:
        // Merge loci per gene
        gene_arg = genes.join("\n")
        '''
        echo "!{gene_arg}" > genes.txt

        touch cis_loci_merged_per_gene.bed
        touch trans_loci_merged_per_gene.bed

        grep "True" !{variantBed} > cis_effects.bed
        grep "False" !{variantBed} > trans_effects.bed

        while read g; do
          echo $g
          grep "$g" cis_effects.bed | bedtools merge -d !{variantFlankSize} >> cis_loci_merged_per_gene.bed
          grep "$g" trans_effects.bed | bedtools merge -d !{variantFlankSize} >> trans_loci_merged_per_gene.bed
        done <genes.txt

        bedtools intersect \
          -a cis_loci_merged_per_gene.bed \
          -b trans_loci_merged_per_gene.bed \
          -wa -wb | \
        awk -F'\t' 'BEGIN {OFS = FS} { printf "%s\n%s",$4,$9; }' > cis_trans_intersection_genes.bed
        '''
}

process AnnotateLoci {
    publishDir "${params.output}/loci_empirical_annotated", mode: 'copy', overwrite: true

    input:
        tuple val(locus_string), path(files, stageAs: "locus_*.csv")
        path variantReference
        path geneReference
        path mafTable
        path inclusionDir

    output:
        tuple val(locus_string), path("annotated.${locus_string}.csv.gz")

    script:
        """
        head -n 1 ${files[0]} > concatenated.${locus_string}.csv
        tail -n +2 ${files.join(' ')} >> concatenated.${locus_string}.csv

        annotate_loci.py \
            --input-file concatenated.${locus_string}.csv \
            --variant-reference ${variantReference} \
            --gene-gff ${geneReference} \
            --maf-table ${mafTable} \
            --inclusion-path ${inclusionDir} \
            --out-prefix annotated.${locus_string}
        """
}

process ConcatLoci {
    publishDir "${params.output}/loci_permuted", mode: 'copy', overwrite: true

    input:
        tuple val(locus_string), path(files, stageAs: "locus_*.csv")

    output:
        path "concatenated.${locus_string}.csv.gz"

    script:
        """
        head -n 1 ${files[0]} > concatenated.${locus_string}.csv
        tail -n +2 ${files.join(' ')} >> concatenated.${locus_string}.csv
        gzip -f concatenated.${locus_string}.csv
        """
}