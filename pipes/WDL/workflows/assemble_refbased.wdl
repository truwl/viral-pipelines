import "../tasks/tasks_assembly.wdl" as assembly
import "../tasks/tasks_reports.wdl" as reports

workflow assemble_refbased {

  File     reference_fasta
  File     reads_unmapped_bam
  File?    novocraft_license
  Boolean? skip_mark_dupes=false

  call reports.plot_coverage as plot_initial {
    input:
        assembly_fasta     = reference_fasta,
        reads_unmapped_bam = reads_unmapped_bam,
        novocraft_license  = novocraft_license,
        skip_mark_dupes    = skip_mark_dupes
  }

  call assembly.ivar_trim {
    input:
        aligned_bam = plot_initial.aligned_only_reads_bam
  }

  call assembly.refine_assembly_with_aligned_reads as polish {
    input:
        reference_fasta   = reference_fasta,
        reads_aligned_bam = ivar_trim.aligned_trimmed_bam,
        novocraft_license  = novocraft_license
  }

  call reports.plot_coverage as plot_final {
    input:
        assembly_fasta     = polish.refined_assembly_fasta,
        reads_unmapped_bam = reads_unmapped_bam,
        novocraft_license  = novocraft_license,
        skip_mark_dupes    = skip_mark_dupes
  }

}
