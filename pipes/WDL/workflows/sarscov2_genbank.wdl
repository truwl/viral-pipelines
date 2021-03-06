version 1.0

import "../tasks/tasks_ncbi.wdl" as ncbi
import "../tasks/tasks_nextstrain.wdl" as nextstrain
import "../tasks/tasks_reports.wdl" as reports

workflow sarscov2_genbank {

    meta {
        description: "Prepare SARS-CoV-2 assemblies for Genbank submission. This includes QC checks with NCBI's VADR tool and filters out genomes that do not pass its tests."
        author: "Broad Viral Genomics"
        email:  "viral-ngs@broadinstitute.org"
    }

    input {
        Array[File]+  assemblies_fasta

        File          authors_sbt
        File          biosample_attributes
        File          assembly_stats_tsv
        File?         fasta_rename_map

        Int           min_genome_bases = 15000
        Int           max_vadr_alerts = 0

        Int           taxid = 2697049
        String        gisaid_prefix = 'hCoV-19/'
    }

    parameter_meta {
        assemblies_fasta: {
          description: "Genomes to prepare for Genbank submission. One file per genome: all segments/chromosomes included in one file. All fasta files must contain exactly the same number of sequences as reference_fasta (which must equal the number of files in reference_annot_tbl).",
          patterns: ["*.fasta"]
        }
        authors_sbt: {
          description: "A genbank submission template file (SBT) with the author list, created at https://submit.ncbi.nlm.nih.gov/genbank/template/submission/",
          patterns: ["*.sbt"]
        }
        biosample_attributes: {
          description: "A post-submission attributes file from NCBI BioSample, which is available at https://submit.ncbi.nlm.nih.gov/subs/ and clicking on 'Download attributes file with BioSample accessions'.",
          patterns: ["*.txt", "*.tsv"]
        }
        assembly_stats_tsv: {
          description: "A four column tab text file with one row per sequence and the following header columns: SeqID, Assembly Method, Coverage, Sequencing Technology",
          patterns: ["*.txt", "*.tsv"]
        }
    }

    scatter(assembly in assemblies_fasta) {
        if(defined(fasta_rename_map)) {
          String fasta_basename = basename(assembly, ".fasta")
          call ncbi.rename_fasta_header {
            input:
              genome_fasta = assembly,
              new_name = read_map(select_first([fasta_rename_map]))[fasta_basename]
          }
        }
        call reports.assembly_bases {
          input:
            fasta = assembly
        }
        File renamed_assembly = select_first([rename_fasta_header.renamed_fasta, assembly])
        call ncbi.vadr {
          input:
            genome_fasta = renamed_assembly
        }
        if (assembly_bases.assembly_length_unambiguous >= min_genome_bases) {
          if (vadr.num_alerts <= max_vadr_alerts) {
            File passing_assemblies = renamed_assembly
          }
          if (vadr.num_alerts > max_vadr_alerts) {
            File weird_assemblies = renamed_assembly
          }
       }
    }

    # prep the good ones
    call nextstrain.concatenate as passing_fasta {
      input:
        infiles = select_all(passing_assemblies),
        output_name = "assemblies-passing.fasta"
    }
    call nextstrain.fasta_to_ids as passing_ids {
      input:
        sequences_fasta = passing_fasta.combined
    }

    # prep the weird ones
    call nextstrain.concatenate as weird_fasta {
      input:
        infiles = select_all(weird_assemblies),
        output_name = "assemblies-weird.fasta"
    }
    call nextstrain.fasta_to_ids as weird_ids {
      input:
        sequences_fasta = weird_fasta.combined
    }

    # package genbank
    call ncbi.biosample_to_genbank as passing_source_modifiers {
      input:
        biosample_attributes = biosample_attributes,
        num_segments = 1,
        taxid = taxid,
        filter_to_ids = passing_ids.ids_txt
    }
    call ncbi.structured_comments as passing_structured_cmt {
      input:
        assembly_stats_tsv = assembly_stats_tsv,
        filter_to_ids = passing_ids.ids_txt
    }
    call ncbi.package_genbank_ftp_submission as passing_package_genbank {
      input:
        sequences_fasta = passing_fasta.combined,
        source_modifier_table = passing_source_modifiers.genbank_source_modifier_table,
        author_template_sbt = authors_sbt,
        structured_comment_table = passing_structured_cmt.structured_comment_table
    }

    # translate to gisaid
    call ncbi.prefix_fasta_header as passing_prefix_gisaid {
      input:
        genome_fasta = passing_fasta.combined,
        prefix = gisaid_prefix,
        out_basename = "gisaid-passing-sequences"
    }
    call ncbi.gisaid_meta_prep as passing_gisaid_meta {
      input:
        source_modifier_table = passing_source_modifiers.genbank_source_modifier_table,
        structured_comments = passing_structured_cmt.structured_comment_table,
        fasta_filename = "gisaid-passing-sequences.fasta",
        out_name = "gisaid-passing-meta.tsv"
    }

    # package genbank
    call ncbi.biosample_to_genbank as weird_source_modifiers {
      input:
        biosample_attributes = biosample_attributes,
        num_segments = 1,
        taxid = taxid,
        filter_to_ids = weird_ids.ids_txt
    }
    call ncbi.structured_comments as weird_structured_cmt {
      input:
        assembly_stats_tsv = assembly_stats_tsv,
        filter_to_ids = weird_ids.ids_txt
    }
    call ncbi.package_genbank_ftp_submission as weird_package_genbank {
      input:
        sequences_fasta = weird_fasta.combined,
        source_modifier_table = weird_source_modifiers.genbank_source_modifier_table,
        author_template_sbt = authors_sbt,
        structured_comment_table = weird_structured_cmt.structured_comment_table
    }

    # translate to gisaid
    call ncbi.prefix_fasta_header as weird_prefix_gisaid {
      input:
        genome_fasta = weird_fasta.combined,
        prefix = gisaid_prefix,
        out_basename = "gisaid-weird-sequences"
    }
    call ncbi.gisaid_meta_prep as weird_gisaid_meta {
      input:
        source_modifier_table = weird_source_modifiers.genbank_source_modifier_table,
        structured_comments = weird_structured_cmt.structured_comment_table,
        fasta_filename = "gisaid-weird-sequences.fasta",
        out_name = "gisaid-weird-meta.tsv"
    }

    output {
        File submission_zip = passing_package_genbank.submission_zip
        File submission_xml = passing_package_genbank.submission_xml
        File submit_ready   = passing_package_genbank.submit_ready

        Int  num_successful = length(select_all(passing_assemblies))
        Int  num_weird = length(select_all(weird_assemblies))
        Int  num_input = length(assemblies_fasta)

        Array[File] vadr_outputs = vadr.outputs_tgz

        File gisaid_fasta = passing_prefix_gisaid.renamed_fasta
        File gisaid_meta_tsv = passing_gisaid_meta.meta_tsv

        File weird_genbank_zip = weird_package_genbank.submission_zip
        File weird_genbank_xml = weird_package_genbank.submission_xml
        File weird_gisaid_fasta = weird_prefix_gisaid.renamed_fasta
        File weird_gisaid_meta_tsv = weird_gisaid_meta.meta_tsv
    }

}
