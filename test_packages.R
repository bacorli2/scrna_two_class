



# Test Package code, scRNA-seq workshop                          ###############
#______________________________________________________________________________
# This code produces all figures in the slides for the workshop and tests if 
# packages required for workshop is functional.


# Instructions                                                ##################
#_______________________________________________________________________________
# 1. Set current working directory to the location of this source file.
# 2. Run this script.
# 3. If you encounter errors, 
#    1. Try to install any required packages.
#    2. Check packages are up-to-date: update.packages() and biocmanager::valid()
#    3. Google errors and attempt to debug

library(tidyverse)
library(Seurat)
library(patchwork)
library(HGNChelper)
library(openxlsx)
library(presto)
library(scAnnotatR)
library(SingleR)
library(celldex)
library(SeuratWrappers)
library(cowplot)
require(DESeq2)
# library(DESeq2)
options(ggrepel.max.overlaps = Inf) 

# Set wd to base of workshop repository
here::i_am("README.md")


# Create data directory for workshop
dir.create(here::here("_temp_data"))


# scRNA-seq Dataset Importation                                     ############
#_______________________________________________________________________________
# Example small dataset (real data)
# Used from this tutorial: https://satijalab.org/seurat/articles/pbmc3k_tutorial
# 2,700 single cells that were sequenced on the Illumina NextSeq 500
# 13,714 genes
# Download dataset into temp_data, unzip
pbmc3k_path <- here::here("_temp_data", "pbmc3k_filtered_gene_bc_matrices.tar.gz")
if (!file.exists(pbmc3k_path)) {
  dir.create("_temp_data")
  download.file("https://cf.10xgenomics.com/samples/cell/pbmc3k/pbmc3k_filtered_gene_bc_matrices.tar.gz",
                destfile = pbmc3k_path)
  untar(pbmc3k_path, exdir = "_temp_data/")
}
# Load the srat dataset
srat.data <- Read10X(data.dir = here::here("_temp_data", 
                                           "filtered_gene_bc_matrices/hg19"))


# Initialize the Seurat object with the raw count matrix (non-normalized data).
# min:cells: include genes that are found within at least 3 cells
# min.features: include cells that have at least 200 genes
srat <- CreateSeuratObject(counts = srat.data, project = "pbmc3k", 
                           min.cells = 3, min.features = 200)

# Add column in metadata slot for percent of mitochondrial genes (QC metric)
srat[["percent.mt"]] <- PercentageFeatureSet(srat, pattern = "^MT-")

# Visualize QC metrics as a violin plot
# nFeature_RNA: total number of genes detected in each cell
# nCount_RNA: total number of molecules detected within a cell (library size)
# percent.mt: fraction of genes that are mitochondrial (qc metric)
VlnPlot(srat, features = "percent.mt", ncol = 3)
VlnPlot(srat, features = c("nFeature_RNA", "nCount_RNA", "percent.mt"), 
        ncol = 3)

## Filter poor quality cells                          ##########################
#_______________________________________________________________________________
# nFeature_RNA > 200: removes empty droplets or cells with little RNA
# nFeature_RNA < 25000: remove doublets (droplets with 2+ cells)
# percent.mt < 5: removes cells with over 5% mitochondrial DNA 
# (poor viability)
srat <- subset(srat, subset = nFeature_RNA > 200 & nFeature_RNA < 2500 & 
                 percent.mt < 5)


## Normalize data                                     ##########################
#_______________________________________________________________________________
# 1. Normalizes gene expression by the total expression in each cell
# 2. Multiplies this by a scale factor (10,000 by default)
# 3. Log-transforms the result.
# Stored in: srat[["RNA"]]$data
srat <- NormalizeData(srat, normalization.method = "LogNormalize", 
                      scale.factor = 10000)

## Feature Selection                                #############################
#_______________________________________________________________________________
# Identify highly variables genes, (to be used for dimension reduction)
srat <- FindVariableFeatures(srat, selection.method = "vst", nfeatures = 2000)

## Scale the data                                                 ##############
#_______________________________________________________________________________
# Essentially converts gene expression to z-score (normalize by mean and std 
# across cells)
# Stored in: srat[["RNA"]]$scale.data
srat <- ScaleData(srat, features = rownames(srat))

## Scale data can also be used to remove unwanted cell cycle variation #########
# However, this is a more advance method, and it is recommended to use the new
# Seurat workflow: SCTransform(). 
# Paper: https://genomebiology.biomedcentral.com/articles/10.1186/
#        s13059-021-02584-9
# Vignette: https://satijalab.org/seurat/articles/sctransform_vignette
# srat <- ScaleData(srat, vars.to.regress = "percent.mt")

 
## PCA: Linear dimension reduction ############################################
#_______________________________________________________________________________
srat <- RunPCA(srat, features = VariableFeatures(object = srat))
# Plot commands: VizDimReduction(), DimPlot(), and DimHeatmap()
VizDimLoadings(srat, dims = 1:2, reduction = "pca")     
DimHeatmap(srat, dims = 1, cells = 500, balanced = TRUE)
DimPlot(srat, reduction = "pca") + NoLegend()

# Choose dimensionality of the dataset
# Maximize the signal (biological variability) to the noise (other sources of 
# variation)
ElbowPlot(srat)



## Dataset Integration (Simulated) ##############################################
#_______________________________________________________________________________
# For illustrative purposes, let's simulate having data from two conditions
# We can combine the data between them and instruct seurat to normalize the data
# To make comparable.
#  Groups: 0: control, 1: treatment
# We can do this by adding a factor to the seurat metadata
set.seed(0)
srat_int <- srat
srat_int@meta.data$group_id = factor(rbinom(n = ncol(srat_int), size = 1, 
                                            prob = 0.5 ), labels = c("Ctrl","Tx"))
# Split dataset based on factor column in metadata
srat_int[["RNA"]] <- split(srat_int[["RNA"]], f = srat_int$group_id)
# Integrate datasets together in seurat object
srat_int <- 
  IntegrateLayers(srat_int, method = CCAIntegration, orig.reduction = "pca", 
                  new.reduction = "integrated.cca", verbose = FALSE)
# Re-join layers after integration
srat_int[["RNA"]] <- JoinLayers(srat_int[["RNA"]])
# Rerun pipeline
srat_int <- FindNeighbors(srat_int, dims = 1:10)
srat_int <- FindClusters(srat_int, resolution = 0.5)
srat_int <- RunUMAP(srat_int, dims= 1:10)
# Visualize UMAP clusters
DimPlot(srat_int, reduction = "umap", label = TRUE,
        repel = TRUE)
# Overwrite seurat object for downstream steps
srat <- srat_int




## Clustering ##################################################################
#_______________________________________________________________________________
# Construct a kNN graph based on euclidean distance in a subset of PCA space 
#  (up to dimensionality chosen).
# Refine edge weights between pairs of cells based on their shared overlap and 
# local neighboors (Jaccard similarity)
srat <- FindNeighbors(srat, dims = 1:10)

# Clustering Cells: we next apply modularity optimization 
# (Louvain algorithm, SLM ) to iteratively group cells together, with the goal 
# of optimizing the standard modularity function. 
# Cluster granularity is set with resolution, 0.4-1.2 typically returns good 
# results for single-cell datasets of around 3K cells. Resolution often 
# increases for larger datasets.
srat <- FindClusters(srat, resolution = 0.5)
DimPlot(srat, reduction = "pca") + NoLegend()


## UMAP: Nonliner Dimension Reduction                       #######################
#_______________________________________________________________________________
srat <- RunUMAP(srat, dims= 1:10)

# Visualize UMAP clusters
DimPlot(srat, reduction = "umap", label = TRUE, repel = TRUE)

# Gene expression in each cluster
# VlnPlot(data, features = c("Pax6", "Rbfox1"), slot = "counts", log = TRUE)

# FeaturePlot(data, features = c("Pax6",  "Eomes", "Aldh1l1",
#                                "Tbr1",  "Olig2", "Sox2", "Cux2", "Neurog2"))

# Save srat file (subsetted) to explore object structure
# small_srat <- srat[1:10000,1:200]
# save(small_srat, file = here::here("_temp_data","srat_example_object.RData"))

# # Parameter sweep
# res <- seq(0.1,2,.2)
# res <- c(0.01, 0.1, 0.2, 0.4, 0.8, 1, 1.5, 2, 5, 10)
# for (n in seq_along(res)){
#   srat <- FindClusters(srat, resolution = res[n])
#   # Perform UMAP clustering
#   srat <- RunUMAP(srat, dims= 1:10)
#   gg <- DimPlot(srat, reduction = "umap", label = TRUE, repel = TRUE) + 
#     theme(legend.position = "none") + ggtitle(sprintf("Res = %.2f", res[n]))
#   cowplot::save_plot(here::here("_temp_out", sprintf("umap_res-%.1f.png", res[n])),
#                      gg,  base_height = 3, base_width = 3)
# 
# }


# # Parameter sweep
# pdims <- c(2,3,4, 5,10,15,20,50)
# for (n in seq_along(pdims)){
#   srat <- FindNeighbors(srat, dims = 1:pdims[n])
#   srat <- FindClusters(srat, resolution = 0.5)
#   # Perform UMAP clustering
#   srat <- RunUMAP(srat, dims= 1:pdims[n])
#   gg <- DimPlot(srat, reduction = "umap", label = TRUE, repel = TRUE) + 
#     theme(legend.position = "none") + ggtitle(sprintf("Dims = %.0f", pdims[n]))
#   cowplot::save_plot(here::here("_temp_out", sprintf("umap_dims-%.0f.png", pdims[n])),
#                      gg,  base_height = 3, base_width = 3)
#   
# }


# Cluster Marker Identification ################################################
#_______________________________________________________________________________

# Find differentially expressed genes in each cluster vs. all other clusters
# Test used is non-parametric Wilcoxon rank sum test
# Note: Install presto package for much faster results
srat_int.all.markers <- FindAllMarkers(srat_int, only.pos = TRUE)


## Cell Type Annotation: ScType ###############################################
#_______________________________________________________________________________
#https://github.com/IanevskiAleksandr/sc-type/blob/master/README.md
# Load gene set and cell type annotation functions into memory
source(paste0("https://raw.githubusercontent.com/IanevskiAleksandr/sc-type/",
              "master/R/gene_sets_prepare.R"))
source(paste0("https://raw.githubusercontent.com/IanevskiAleksandr/sc-type/",
              "master/R/sctype_score_.R"))
# DB file
db_ = paste0("https://raw.githubusercontent.com/IanevskiAleksandr/sc-type/",
             "master/ScTypeDB_full.xlsx")
tissue = "Immune system"
# e.g. Immune system,Pancreas,Liver,Eye,Kidney,Brain,Lung,Adrenal,Heart,
# Intestine,Muscle,Placenta,Spleen,Stomach,Thymus


# Prepare gene sets
gs_list = gene_sets_prepare(db_, tissue)

# Get score matrix: cell-type (row) by cell (col)
# NOTE: scRNAseqData argument should correspond to your input scRNA-seq matrix.
#   In case Seurat is used, it is either
#   1. srat[["RNA"]]@scale.data (default),
#   2. srat[["SCT"]]@scale.data, if sctransform is used for normalization,
#   3. srat[["integrated"]]@scale.data, for joint analysis of multiple datasets.
es.max = sctype_score(scRNAseqData = srat[["RNA"]]$scale.data, scaled = TRUE,
                      gs = gs_list$gs_positive, gs2 = gs_list$gs_negative)


# Merge by cluster
# For each cluster, grab all cells that below to it, find top10 best matches
# for cell type
cL_resutls = do.call("rbind", lapply(unique(srat@meta.data$seurat_clusters),
                                     function(cl){
  es.max.cl = sort(rowSums( es.max[ ,rownames(srat@meta.data[
    srat@meta.data$seurat_clusters==cl, ])]), decreasing = TRUE)
  head(data.frame(cluster = cl, type = names(es.max.cl), scores = es.max.cl,
                  ncells = sum(srat@meta.data$seurat_clusters==cl)), 10)
}))
# Grab best cell-type match for each cluster, assign as final cell-type
sctype_scores = cL_resutls %>% group_by(cluster) %>% top_n(n = 1, wt = scores)

# Set low-confident (low ScType score) clusters to "Unknown"
# Sctype scores scale by n, so threshold is ncells/4
sctype_scores$type[as.numeric(as.character(sctype_scores$scores)) <
                     sctype_scores$ncells/4] = "Unknown"
print(sctype_scores[,1:3])

# Add column in seurat metadata for celltype annotation
srat@meta.data$cell_type <- factor(select(srat@meta.data, "seurat_clusters") %>%
  left_join(y = select(sctype_scores, "cluster", "type"),
            by = join_by(seurat_clusters == cluster)) %>% pull("type"))
# Relabel cell identity label to cell_type (previously was cluster number)
Idents(srat) <- srat@meta.data$cell_type

# UMAP Plot of Scitype annotated cells
DimPlot(srat, reduction = "umap", label = TRUE, repel = TRUE,
        group.by = 'cell_type') +
  ggtitle("SciType Annotated Cells")


## Cell Classification Using scAnnotateR #######################################
#_______________________________________________________________________________
# DEFAULT MODEL: Load classification Models
default_models <- scAnnotatR::load_models("default")

# Perform classification
srat_scannot <- classify_cells(classify_obj = srat,
                             assay = 'RNA', slot = 'counts',
                             cell_types = "all",
                             path_to_models = 'default')
# Plot best match for each cell_type
DimPlot(srat_scannot, group.by = "most_probable_cell_type")



## Classification Based Cell Type: scPred ######################################
#_______________________________________________________________________________
# There is an error with scPredict and the github has not been updated in a 
# while, so we load a corrected version of function into memory.  
source(here::here("R_override", "scPredict_edited.R"))

# Process reference through seurat and scPred
ref_data <- scPred::pbmc_1 %>%
    NormalizeData() %>%
    FindVariableFeatures() %>%
    ScaleData() %>%
    RunPCA() %>%
    RunUMAP(dims = 1:30)
ref_model <- scPred::getFeatureSpace(ref_data, "cell_type")
ref_model <- scPred::trainModel(ref_model)

# Visualize Model Data
DimPlot(ref_data, group.by = "cell_type", label = TRUE,
        repel = TRUE) +
  ggtitle("scPred:: PBMC_1 Reference")

# Visualize predicted cell types
srat_scpred <- scPredict_edited(srat, ref_model)
DimPlot(srat_scpred, group.by = "scpred_prediction", label = TRUE,
        repel = TRUE) +
  ggtitle("Cell Types Predicted by scPred")




## Cell Classification with SingleR#############################################
#_______________________________________________________________________________
# Load dataset of immune cells bulk RNA-seq (platelets not included)
ref.se <- celldex::DatabaseImmuneCellExpressionData()
# Label celltypes in our srat dataset
pred.hesc <- SingleR::SingleR(test = srat@assays$RNA$counts, ref = ref.se,
                              assay.type.test=1,
                     labels = ref.se$label.fine)

# Add labels to metadata in srat object
srat@meta.data$singler_cell_types <- pred.hesc$pruned.labels
# UMAP Plot of Scitype annotated cells
DimPlot(srat, reduction = "umap", label = TRUE, repel = TRUE,
        group.by = 'singler_cell_types') +
  ggtitle("SingleR with celldex::ImmuneDataset Ref")



# Exploratory Analysis (misc extra plots)#######################################
#_______________________________________________________________________________
# Visualize QC metrics as a violin plot
Idents(srat) <- "pbmc3k"
VlnPlot(srat, features = c("nFeature_RNA", "nCount_RNA", "percent.mt"), 
        ncol = 3,  idents = NULL, group.by = NULL,  split.by = NULL,   
        assay = "RNA")
# Compare QC features pairwise
plot1 <- FeatureScatter(srat, feature1 = "nCount_RNA", 
                        feature2 = "percent.mt")
plot2 <- FeatureScatter(srat, feature1 = "nCount_RNA", 
                        feature2 = "nFeature_RNA")
plot1 + plot2


# Plot Variable features
plot1 <- VariableFeaturePlot(srat)
plot1
# Label Most variable features
plot2 <- LabelPoints(plot = plot1, points = head(VariableFeatures(srat), 10), 
                     repel = TRUE)
plot2


# Visualize PCA Dim as scatter plot
VizDimLoadings(srat, dims = 1:2, reduction = "pca")

# Visualize PCA Dim as heatmap
DimHeatmap(srat, dims = 1:2, cells = 500, balanced = TRUE)

Idents(srat) <- srat$seurat_clusters
# Visualize gene expression of Top 2 Variable Genes across clusters
VlnPlot(srat, features = head(VariableFeatures(srat), 2))

# Visualize heatmap of genes across clusters
FeaturePlot(srat, features = c("MS4A1", "GNLY", "CD3E", "CD14", "FCER1A", 
                               "FCGR3A", "LYZ", "PPBP", "CD8A"))


# Heatmap of expression of top markers
topn <- srat_int.all.markers %>%
  group_by(cluster) %>%
  dplyr::filter(avg_log2FC > 1) %>%
  slice_head(n = 5) %>%
  ungroup() 
DoHeatmap(srat, features = topn$gene) +
  NoLegend()



# DGE and Conserved Gene Expression ############################################
#_______________________________________________________________________________
# https://satijalab.org/seurat/archive/v3.1/immune_alignment.html
# We use the simulated integrated dataset we created previously (randomly 
# assigning cells between (0) control group and (1) treatment group).
DefaultAssay(srat_int) <- "RNA"

# UMAP Plot of Scitype annotated cells
DimPlot(srat, reduction = "umap", label = TRUE, repel = TRUE,
        group.by = 'cell_type') +
  ggtitle("SciType Annotated Cells")

# Visualize UMAP clusters
DimPlot(srat, reduction = "umap", label = TRUE, repel = TRUE)


## Identify Conserved markers across conditions ################################
#_______________________________________________________________________________
conserved_marks <- FindConservedMarkers(srat_int, ident.1 = 1,   
                                          grouping.var = "group_id",
                                          verbose = FALSE)
head(conserved_marks)

### Visualize Top conserved markers for classical monocytes for all clusters 
#_______________________________________________________________________________
# Minimum cut-off set to 9th quantile
FeaturePlot(srat, features = rownames(head(conserved_marks)),
            min.cutoff = "q9")

### Visualize conserved marker expression with dot plot 
#_______________________________________________________________________________
DotPlot(srat, features = rev(rownames(conserved_marks[1:10,])), 
        cols = c("blue", "red"), dot.scale = 8,  split.by = "group_id") + 
  RotatedAxis()


## Differential Gene Expression: Option 1 (Naive) 
# Subset by each cell_type, find diff markers between conditions
#_______________________________________________________________________________
# Caution: With multiple samples, does not control for within sample variation
# Relabel cell identity label to cell_type (previously was cluster number)
cell_types <- levels(srat@meta.data$cell_type)
diff_markers = list()
for (n in seq_along(cell_types)) {
  # Isolate cells from first cell type/cluster
  sub_srat = subset(srat, cell_type == cell_types[n])
  # Reassign idents for finding markers
  Idents(sub_srat) = srat@meta.data$group_id
  diff_markers[[cell_types[n]]] <- 
    FindMarkers(sub_srat, ident.1 = "Ctrl", ident.2 = "Tx", slot = "scale.data")
  head(diff_markers[[cell_types[n]]], n = 10)
}

# Visualize diff marker expression with dot plot 
Idents(srat) <- srat$cell_type
DotPlot(srat, features = rev(rownames(diff_markers$`Classical Monocytes`)[1:10]), 
        cols = c("blue", "red"), dot.scale = 8,  split.by = "group_id") + 
  RotatedAxis()



## Option 2: Visualize Differential Expressed Genes ############################
#_______________________________________________________________________________
# celltypes <- levels(Idents(srat))
# for (n in seq_along(celltypes)) {
#   sub_srat <- subset(srat, idents = celltypes[n])
#   Idents(sub_srat) <- "stim"
#   avg.t.cells <- log1p(AverageExpression(sub_srat, verbose = FALSE)$RNA)
#   avg.t.cells$gene <- rownames(avg.t.cells)
# 
# }

# Heatmap of gene expression between study groups across all cell types
FeaturePlot(srat, features = c("LYZ", "ISG15"),
            split.by = "group_id", max.cutoff = 3,
            cols = c("grey", "red"))


# Visualize expression between study groups across all cell types
plots <- VlnPlot(srat, features = c("LYZ", "ISG15"), split.by = "group_id",
                 group.by = "cell_type", pt.size = 0, combine = FALSE,
                 split.plot = FALSE)
wrap_plots(plots = plots, ncol = 1)




## Differential Gene Expression: Option 3, Psuedo-bulk analysis ################
#_______________________________________________________________________________
# https://satijalab.org/seurat/articles/de_vignette

# Note: only works if tissue acquired from multiple replicates (not the case
#  with this dataset).So we simulate replicates.
srat$sample_id <- sample(x = 1:10, size = ncol(srat), replace = TRUE)

# Perform pseudo bulk, grouping gene expression by cell_type, group_id, 
#   and donor (can also group by sample/ donor if that exists in dataset)
pseudo_srat <- AggregateExpression(
  object = srat, assays = "RNA", return.seurat = T,
  group.by = c("group_id",  "cell_type", "sample_id"))
# For pseudo bulk testing we need to group by cell type and study group
pseudo_srat$celltype.tx <- paste(pseudo_srat$cell_type, 
                                 pseudo_srat$group_id, sep = "_")

# Set primary identify/groups for cells for DGE test
Idents(pseudo_srat) <- "celltype.tx"
bulk.mono.de <- FindMarkers(object = pseudo_srat, 
                            ident.1 = "Classical Monocytes_Ctrl", 
                            ident.2 = "Classical Monocytes_Tx",
                            test.use = "DESeq2")
head(bulk.mono.de, n = 10)

### Visualize differentially expressed markers from pseudobulk analysis ########
#_______________________________________________________________________________
Idents(srat) <- srat$cell_type
DotPlot(srat, features = rev(rownames(bulk.mono.de)[1:10]), 
        cols = c("blue", "red"), dot.scale = 8,  split.by = "group_id") + 
  RotatedAxis()



