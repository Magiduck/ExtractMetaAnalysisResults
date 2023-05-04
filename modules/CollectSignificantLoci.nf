#!/bin/bash nextflow

process ExtractSignificantResults {
    scratch true

    input:
        path input
        val genes
        val p_value

    output:
        path "loci.txt"

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
            --output-file loci.txt
        '''
}

process AnnotateResults {
    input:
        path significantResults
        path variantReference
        path geneReference

    output:
        path "loci.variants.bed", emit: variant_loci
        path "loci.genes.bed", emit: gene_loci

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
        path geneLoci
        val geneFlankSize
        path bedFile
        path genomeRef

    output:
        path "merged.bed"

    script:
        // Define background bed file to take into account
        def bed = bedFile.name != 'NO_FILE' ? "$bedFile" : ''

        // Calculate flanks for genes, calculate flanks for snps, calculate union.
        """
        bedtools slop -i "${variantLoci}" -g "${genomeRef}" -b "${variantFlankSize}" > "variant_loci.flank.bed"

        cat "variant_loci.flank.bed" ${bed} > "total.flank.bed"

        # Get the union of the two bed files (including flanks)
        bedtools sort -i "total.flank.bed" > "total.flank.sorted.bed"
        bedtools merge -i "total.flank.sorted.bed" -d 0 -c 4 -o distinct > "merged.bed"
        """
}

process SelectFollowUpLoci {
    input:
        path variantLoci
        val variantFlankSize
        path geneLoci
        val geneFlankSize
        path bedFile
        path genomeRef

    output:
        path "selection.bed"

    script:
        // Flank loci and find the union between them, filtering on combinations where EITHER of the below is true:
        // 1. There is a cis genes involved
        // 2. There is a locus involved from the supplementary bed file
        """
        bedtools slop -i "${geneLoci}" -g "${genomeRef}" -b "${geneFlankSize}" > "gene_loci.flank.bed"
        bedtools intersect -wa -a "${variantLoci}" -b "${gene_loci.flank.bed}" "${bed}" -sorted > variant_loci.intersect.bed
        bedtools slop -i variant_loci.intersect.bed -g "${genomeRef}" -b "${variantFlankSize}" > "variant_loci.flank.bed"

        cat "variant_loci.flank.bed" ${bed} > "total.flank.bed"

        # Get the union of the two bed files (including flanks)
        bedtools sort -i "total.flank.bed" > "total.flank.sorted.bed"
        bedtools merge -i "total.flank.sorted.bed" -d 0 -c 4 -o distinct > "selection.bed"
        """
}

process ExtractLoci {
    input:
        path eqtls
        val genes
        path variantReference
        val loci

    output:
        path "extractedResults.csv"

    script:
        gene_arg = genes.join(" ")
        phenotypes_formatted = genes.collect { "phenotype=$it" }.join("\n")
        '''
        mkdir tmp_eqtls
        echo "!{phenotypes_formatted}" > file_matches.txt

        while read gene; do
          cp -r "!{input}/${gene}" tmp_eqtls/
        done <file_matches.txt

        echo "${loci}" > "loci.txt"

        extract_parquet_results.py \
            --input-file tmp_eqlts \
            --cols "+p_value" \
            --loci loci.txt \
            --output-file extractedResults.csv
        '''
}

process AnnotateLoci {
    input:
        path significantResults
        path variantReference
        path geneReference
        path mafTable
        path inclusionDir

    output:
        path "annotated.cvs.gz"

    script:
        """
        annotate_loci.py \
            --input-file ${significantResults} \
            --variant-reference ${variantReference} \
            --gene-ggf ${geneReference} \
            --maf-table ${mafTable} \
            --inclusion-path ${inclusionDir} \
            --out-prefix "annotated"
        """
}
