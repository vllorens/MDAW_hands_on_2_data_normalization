# Microbiome data analysis workshop
# Hands on #2, part 1: Data normalization
# Instructor: Veronica Llorens-Rico, PhD
# Date: 20/04/2021

# In this tutorial we will work with simulated gut microbiome dataset that we will process with phyloseq and other packages
# The simulated dataset represents a case-control study cohort, with ~50% subjects being healthy controls and
# ~50% having a disease that is associated with lower microbial loads

# The simulated data represents the absolute taxon abundances for all taxa (in cells/gram of stool)
# From the simulated dataset, we generated sequencing data (~20,000 reads per sample, by random subsampling with replacement) 
# and flow cytometry cell counts measurements (correlated with the real microbial loads)

# We will first explore the "real" data, and then we will process the sequencing data following different normalizations
# We will compare how the different normalizations perform in answering specific questions about our cohort

#### Part 0. Package installation and setup ####
packages_cran <- c("BiocManager", "tidyverse", "ggpubr", "zCompositions", "devtools", "rstatix")
for(pkg in packages_cran){
    if(!pkg %in% installed.packages())
        install.packages(pkg)
}

packages_bioconductor <- c("phyloseq", "DESeq2")
for(pkg in packages_bioconductor){
    if(!pkg %in% installed.packages())
        BiocManager::install(pkg, update = F)
}

packages_github <- c("CoDaSeq")
for(pkg in packages_github){
    if(!pkg %in% installed.packages())
        devtools::install_github(pkg, update = F)
}

# make sure the CoDaSeq version is updated
if(packageVersion("CoDaSeq")<"0.99.6"){
    install.packages("CoDaSeq")
}


# Load packages and custom scripts
library(phyloseq)
library(tidyverse)
library(ggpubr)
library(rstatix)
library(CoDaSeq)
library(zCompositions)
library(DESeq2)
source("scripts/rarefy_even_sampling_depth.R")

# Finally, set a random seed for reproducibility
set.seed(777)


#### Part 1. Read and explore original data ####

## 1.1. Construct phyloseq object
original_abundances <- read.table("data/real_community/abundance_table.tsv", header=T, stringsAsFactors=F, sep="\t")
original_taxonomy <- read.table("data/real_community/tax_table.txt", header=T, stringsAsFactors=F, sep="\t")
original_metadata <- read.table("data/real_community/metadata_samples.txt", header=T, stringsAsFactors=F, sep="\t")

ps_original <- phyloseq(otu_table(original_abundances, taxa_are_rows = T),
                        tax_table(as.matrix(original_taxonomy)), # use as.matrix to convert to matrix, otherwise ranks or taxon IDs/ASVs are not well preserved
                        sample_data(original_metadata))

ps_original
# This phyloseq object contains the info from 300 taxa in 200 samples.


## 1.2. Plot top species
ps_top10 <- ps_original # copy the phyloseq object to a new one, as we will modify the taxonomy table

# Replace Species with full name
tax_table(ps_top10)[,"Species"] = paste(tax_table(ps_top10)[,"Genus"], tax_table(ps_top10)[,"Species"])

# Select the top 15 species
top10 <- names(sort(taxa_sums(ps_top10), decreasing=TRUE))[1:10]

# group everything that's not in the top 10 as NA and plot
tax_table(ps_top10)[!rownames(tax_table(ps_top10)) %in% top10,"Species"] <- NA
p <- plot_bar(ps_top10, fill="Species", title = "Top 10 species") + theme_bw()
p


# We may want to order the data by microbial loads
# First we order the sample names according to their microbial loads
order_samples <- rownames(original_metadata[order(original_metadata$microbial_load),])

# then we modify directly in the plotting object
p$data$Sample <- factor(p$data$Sample, levels=order_samples)
p

# We may want to separately plot the controls and the patients
p + facet_wrap(~disease_status, scales="free_x") # each sample belongs only in one group, hence we make the x_scale free to avoid blanks


## 1.3. Differences in microbial loads between patients and controls

# Because we are plotting absolute microbial loads, we can already see a first striking difference 
# between controls and patients: microbial loads tend to be higher in controls.
# This has been observed in the gut microbiome associated to different diseases: IBD and primary sclerosing cholangitis (PSC)
# Ref: 

# To verify these differences, we can plot the total microbial loads 
# We don't need phyloseq for this, we can plot directly from the metadata table

ggboxplot(original_metadata, x="disease_status", y="microbial_load",
          fill="disease_status", add="jitter", 
          xlab="Disease status", ylab="Microbial load", 
          title="Microbial loads in patients and controls",
          legend.title="Disease status") + 
    theme_bw() +
    stat_compare_means(comparisons = list(c("Control", "Patient")))
    
## 1.4. Differences in alpha diversity between patients and controls

# we use phyloseq's built-in estimate_richness function to determine the observed richness
# as well as the Shannon index of diversity in the samples of our dataset
alpha_div <- estimate_richness(ps_original, split = T, measures = c("Observed", "Shannon"))

# we can save this object
write.table(alpha_div, "output/original_alpha_div.txt", col.names=T, row.names=T, quote=F, sep="\t")

# also we can use phyloseq's plotting functions for alpha diversity
plot_richness(ps_original, measures=c("Observed", "Shannon"))

# however, this plot is not very informative. We are interested in knowing whether there are differences among groups of samples
# to do so, we can combine phyloseq's built-in plots with functions from the ggplot2 and ggpubr packages
plot_richness(ps_original, x="disease_status", color="disease_status", measures=c("Observed", "Shannon")) +
    geom_boxplot(color="black", aes(fill=disease_status)) + # add boxplots rather than just the points
    stat_compare_means(comparisons=list(c("Control", "Patient"))) + # test for statistical differences between groups
    theme_bw() +  # from here on, cosmetic changes to the plot
    labs(title = "Alpha diversity in patients and controls", 
         x = "Disease status", 
         colour = "Disease status", 
         fill = "Disease status")


# We can see that there are both significant differences in terms of observed richness
# (there are more different species in control samples) and in terms of Shannon diversity 
# (likely because the abundances of the species in the disease group are more even)


## 1.5. Differences in specific taxa abundances between patients and controls
# For simplicity, we will use wilcoxon rank-sum tests for each taxon

# Extract phyloseq data as tibble
data_original <- psmelt(ps_original) %>% # convert the phyloseq object in a data frame containing all the info
    as_tibble() %>% 
    unite(Species_name, c("Genus", "Species"), sep=" ") %>% 
    dplyr::select(-Kingdom, -Phylum, -Class, -Order, -Family)

data_original$disease_status <- factor(data_original$disease_status, levels=c("Control", "Patient"))

# calculate differential abundances
diff_abundances_real <- data_original %>% 
    group_by(Species_name) %>% 
    wilcox_test(Abundance ~ disease_status) %>% # with this format, we calculate differential abundances for all taxa in a single command
    mutate(p_adjusted=p.adjust(p, method="BH")) # add multiple-testing correction
# calculate also the difference in means between groups (wilcox_test can calculate the difference in medians, but when prevalence is low sometimes is better to determine the mean)
mean_differences_real <- data_original %>% 
    group_by(Species_name, disease_status) %>% 
    mutate(abundance=mean(Abundance)) %>% 
    dplyr::select(Species_name, abundance, disease_status) %>% 
    distinct() %>% 
    ungroup %>% 
    spread(key="disease_status", value="abundance") %>% 
    mutate(estimate=Control-Patient) %>% 
    dplyr::select(-Control, -Patient)
# bind all results together
diff_abundances_real <- diff_abundances_real %>% 
    left_join(mean_differences_real, by="Species_name")

    
diff_abundances_real

# We see that most taxa are more abundant in the Control (estimate > 0 and p_adjusted < 0.05)
# This is expected because globally, microbial loads are higher in the control group

# Is there any opportunist taxa, more abundant in the disease?

diff_abundances_real %>% 
    dplyr::filter(estimate<0, p_adjusted<0.05)

opportunist_taxa <- diff_abundances_real %>% 
    dplyr::filter(estimate<0, p_adjusted<0.05) %>% 
    pull(Species_name)


# Are there any unresponsive taxa that don't change abundances across groups?

diff_abundances_real %>% 
    dplyr::filter(p_adjusted>0.05)

unresponsive_taxa <- diff_abundances_real %>% 
    dplyr::filter(p_adjusted>0.05) %>% 
    pull(Species_name)


# Let's plot the behavior of some of the taxa
# First, a "normal" taxon, Butyricimonas virosa, more abundant in the healthy controls
ggboxplot(data_original %>% dplyr::filter(Species_name=="Butyricimonas virosa"),
          x="disease_status", y="Abundance", 
          add="jitter", fill="disease_status",
          title="Abundances of Butyricimonas virosa in controls and patients", 
          legend.title="Disease status",
          xlab="Disease status") + 
    theme_bw() +
    stat_compare_means(comparisons=list(c("Control", "Patient")))

# Second, one of the opportunistic taxa (the 2nd)

ggboxplot(data_original %>% dplyr::filter(Species_name==opportunist_taxa[2]),
          x="disease_status", y="Abundance", 
          add="jitter", fill="disease_status",
          title=paste0("Abundances of ", opportunist_taxa[2], " in controls and patients"), 
          legend.title="Disease status",
          xlab="Disease status") + 
    theme_bw() +
    stat_compare_means(comparisons=list(c("Control", "Patient")))

# Finally, one of the unresponsive taxa (the 4th)

ggboxplot(data_original %>% dplyr::filter(Species_name==unresponsive_taxa[4]),
          x="disease_status", y="Abundance", 
          add="jitter", fill="disease_status",
          title=paste0("Abundances of ", unresponsive_taxa[4], " in controls and patients"), 
          legend.title="Disease status",
          xlab="Disease status") + 
    theme_bw() +
    stat_compare_means(comparisons=list(c("Control", "Patient")))



#### Part 2. Work with sequencing data and cell counts ####

# In this part, we will work with the (simulated) sequencing data originated from the same cohort
# We also have (simulated) cell counts data - correlated to the actual microbial loads, but with experimental noise added
# We will apply different normalizations and see how they affect the calculations that we have performed

# the abundances file contains the ASV sequence table, corrected by copy number variation of the 16S gene
# the metadata file contains the estimated microbial loads, different from the original ones as the measuring always introduces some error
# the taxonomy file in the same as for the original data, assuming that all taxa are correctly assigned

## 2.1. Construct phyloseq object
seq_abundances <- read.table("data/seq_data/abundance_table.tsv", header=T, stringsAsFactors=F, sep="\t")
seq_taxonomy <- read.table("data/seq_data/tax_table.txt", header=T, stringsAsFactors=F, sep="\t")
seq_metadata <- read.table("data/seq_data/metadata_samples.txt", header=T, stringsAsFactors=F, sep="\t")


ps_seq <- phyloseq(otu_table(seq_abundances, taxa_are_rows = T),
                   tax_table(as.matrix(seq_taxonomy)), # use as.matrix to convert to matrix, otherwise ranks or taxon IDs/ASVs are not well preserved
                   sample_data(seq_metadata))


## 2.2. Plot top species  grouping the samples of patients and controls
ps_top10 <- ps_seq # copy the phyloseq object to a new one, as we will modify the taxonomy table

# Replace Species with full name
tax_table(ps_top10)[,"Species"] = paste(tax_table(ps_top10)[,"Genus"], tax_table(ps_top10)[,"Species"])

# Select the top 15 species
top10 <- names(sort(taxa_sums(ps_top10), decreasing=TRUE))[1:10]

# group everything that's not in the top 10 as NA and plot
tax_table(ps_top10)[!rownames(tax_table(ps_top10)) %in% top10,"Species"] <- NA
p <- plot_bar(ps_top10, fill="Species", title = "Top 10 species") + theme_bw()

# First we order the sample names according to their ESTIMATED microbial loads
# NOTE: the order is not necessarily the same as for the real microbial loads because of the noise introduced by the experimental process
order_samples <- rownames(seq_metadata[order(seq_metadata$estimated_microbial_load),])

# then we modify directly in the plotting object
p$data$Sample <- factor(p$data$Sample, levels=order_samples)

# We may want to separately plot the controls and the patients
p + facet_wrap(~disease_status, scales="free_x") # each sample belongs only in one group, hence we make the x_scale free to avoid blanks

# As made evident by the plot, sequencing does not retain any information of the original differences in microbial loads
# However, we estimated the microbial loads via flow cytometry - is the estimation accurate enough to capture the differences?

ggboxplot(seq_metadata, x="disease_status", y="estimated_microbial_load",
          fill="disease_status", add="jitter", 
          xlab="Sample group", ylab="Estimated microbial load", 
          title="Estimated microbial loads in patients and controls",
          legend.title="Sample group") + 
    theme_bw() +
    stat_compare_means(comparisons = list(c("Control", "Patient")))

# Compare this plot with the one of the original microbial loads. 
# We simulated the cell counting with high correlations with the original microbial loads, 
# as would occur when using a flow cytometer
# Thus, the estimated loads capture well the differences between patients and controls


## 2.3. Apply different data normalizations

# Here, we will apply different data normalizations to the dataset and we will explore later how they affect the different results, 
# comparing with the results obtained in the "real" community
# We will calculate 5 different transformations for this tutorial:
# - Downsizing or rarefaction to even sequencing depth [RMP]
# - Centered-log ratio transformation [CLR]
# - Variance-stabilizing transformation [VST] 
# - Absolute count scaling [ACS]
# - Quantitative microbiome profiling [QMP]

# Before applying normalizations, it is common to remove taxa that are low prevalent 
# While this may remove some relevant taxa, it helps reduce the sparsity of the matrix

# We can filter by prevalence using the prune_taxa() function
# First we select the names of the taxa with >20% of prevalence 
# i.e. those with >30% values distinct from zero
keepTaxa = names(which(apply(seq_abundances,1,function(X){(length(which(X!=0))/length(X))>0.2})))

# Now we can filter using phyloseq's function
ps_seq_filtered = prune_taxa(keepTaxa, ps_seq)
ps_seq_filtered

# Now our phyloseq object has 259 taxa instead of 300
# From the filtered data, we can apply the different normalizations

# We can extract the filtered abundance table for the different manipulations
seq_abundances_filt <- as.data.frame(otu_table(ps_seq_filtered))

## Downsizing or rarefaction
# set seed for downsizing
set.seed(123)
# First rarefy abundances
RMP_abundances <- otu_table(seq_abundances_filt, taxa_are_rows = T)
RMP_abundances <- rarefy_even_depth(RMP_abundances, 
                                    trimOTUs = FALSE, 
                                    replace = F,
                                    sample.size = min(sample_sums(RMP_abundances)), 
                                    verbose = F) 

# Make phyloseq object
ps_RMP <- phyloseq(RMP_abundances,
                   tax_table(as.matrix(seq_taxonomy)), # use as.matrix to convert to matrix, otherwise ranks or taxon IDs/ASVs are not well preserved
                   sample_data(seq_metadata))

## CLR transformation
# For CLR, we first need to input zeros, otherwise we cannot calculate the geometric means properly
# To do so we use the cmultRepl from the zCompositions package
seq_abundances_nozeros <- t(cmultRepl(X = t(seq_abundances_filt), output="p-counts"))
CLR_abundances <- codaSeq.clr(seq_abundances_nozeros)

ps_CLR <- phyloseq(otu_table(CLR_abundances, taxa_are_rows=T),
                   tax_table(as.matrix(seq_taxonomy)), # use as.matrix to convert to matrix, otherwise ranks or taxon IDs/ASVs are not well preserved
                   sample_data(seq_metadata))


## VST (DESeq2 package)
VST_abundances <- varianceStabilizingTransformation(as.matrix(seq_abundances_filt))

ps_VST <- phyloseq(otu_table(VST_abundances, taxa_are_rows=T),
                   tax_table(as.matrix(seq_taxonomy)), # use as.matrix to convert to matrix, otherwise ranks or taxon IDs/ASVs are not well preserved
                   sample_data(seq_metadata))

## ACS (experimental transformation using cell counts)
# For this transformation, we need to get the counts estimated from each sample, as well as the sequencing counts
# They are in the metadata matrix
estimated_cell_counts <- seq_metadata[,"estimated_microbial_load"]
sequencing_counts <- apply(seq_abundances_filt,2,sum) # this gets the counts for the FILTERED abundance table 
# here, it doesn't make a big difference to use the filtered or the original sequencing abundances table
# For simplicity and to compare all methods using the same data, I use the filtered abundance table
# In some specific cases, it could be better to use the original matrix for the normalization and then 
# apply the prevalence filter afterwards (or not at all, depending on your dataset and your research questions)

# Double check that the order of samples is the same 
all.equal(rownames(seq_metadata),names(sequencing_counts))

# Calculate a normalization factor for each sample by dividing the estimated cell counts by the sequencing counts
norm_factors <- estimated_cell_counts/sequencing_counts
ACS_abundances <- sweep(seq_abundances_filt, MARGIN = 2, norm_factors, '*')
ACS_abundances <- round(ACS_abundances)

ps_ACS <- phyloseq(otu_table(ACS_abundances, taxa_are_rows=T),
                   tax_table(as.matrix(seq_taxonomy)), # use as.matrix to convert to matrix, otherwise ranks or taxon IDs/ASVs are not well preserved
                   sample_data(seq_metadata))


## QMP (experimental transformation using cell counts)

# here, we also need the counts estimated from each sample, 
# this time the function requires that we supply them as a table
estimated_cell_counts <- seq_metadata[,"estimated_microbial_load", drop=F]

# Then we can run the function to calculate the QMP abundance table
QMP_abundances <- rarefy_even_sampling_depth(cnv_corrected_abundance_table = seq_abundances_filt, 
                                  cell_counts_table = estimated_cell_counts)
QMP_abundances <- round(QMP_abundances)

ps_QMP <- phyloseq(otu_table(QMP_abundances, taxa_are_rows=T),
                   tax_table(as.matrix(seq_taxonomy)), # use as.matrix to convert to matrix, otherwise ranks or taxon IDs/ASVs are not well preserved
                   sample_data(seq_metadata))


## 2.4 For each normalized dataset, calculate and plot alpha diversity

normalized_data_list <- list(ps_RMP, ps_ACS, ps_QMP)
names_methods <- c("RMP", "ACS", "QMP")

# we don't include CLR or VST because these transformations lead to non-integer values and hence cannot be used 
# to estimate alpha diversity

plot_alpha_diversity_custom_function <- function(ps, method){
    plot_richness(ps, x="disease_status", color="disease_status", measures=c("Observed", "Shannon")) +
    geom_boxplot(color="black", aes(fill=disease_status)) + # add boxplots rather than just the points
    stat_compare_means(comparisons=list(c("Control", "Patient"))) + # test for statistical differences between groups
    theme_bw() +  # from here on, cosmetic changes to the plot
    labs(title = paste0("Alpha diversity in patients and controls - ", method), 
         x = "Disease status", 
         colour = "Disease status", 
         fill = "Disease status")
}

for(i in 1:length(normalized_data_list)){
    print(plot_alpha_diversity_custom_function(normalized_data_list[[i]], names_methods[i]))
}


## How do each of the methods compare to the original data?

# We can also calculate the data and save it
for(i in 1:length(normalized_data_list)){
    print(names_methods[i])
    diversity <- estimate_richness(normalized_data_list[[i]], split = T, measures = c("Observed", "Shannon"))
    print(head(diversity))
    write.table(diversity, file=paste0("output/", names_methods[i], "_alpha_div.txt"),
                col.names=T, row.names=T, quote=F, sep="\t")
}

## Does diversity of the individual samples in the normalized data correlate with the one in the original samples?

# read the 4 datasets and merge into 1 for plotting
diversity_original <- read.table("output/original_alpha_div.txt", header=T, stringsAsFactors = F, sep="\t")
diversity_RMP <- read.table("output/RMP_alpha_div.txt", header=T, stringsAsFactors = F, sep="\t")
diversity_ACS <- read.table("output/ACS_alpha_div.txt", header=T, stringsAsFactors = F, sep="\t")
diversity_QMP <- read.table("output/QMP_alpha_div.txt", header=T, stringsAsFactors = F, sep="\t")

diversity_comparison <- cbind(diversity_original, 
                              diversity_RMP, 
                              diversity_ACS, 
                              diversity_QMP)

colnames(diversity_comparison) <- c("Observed_original", "Shannon_original",
                                    "Observed_RMP", "Shannon_RMP",
                                    "Observed_ACS", "Shannon_ACS",
                                    "Observed_QMP", "Shannon_QMP")

# We reorganize the data for plotting
diversity_comparison <- as_tibble(diversity_comparison) %>% 
    gather(key="Metric", value="Value", -Observed_original, -Shannon_original) %>% 
    separate(Metric, into=c("Metric", "Method")) %>% 
    spread(key="Metric", value="Value")

diversity_comparison$Method <- factor(diversity_comparison$Method, levels=c("RMP", "ACS", "QMP"))

ggscatter(diversity_comparison, x="Observed_original", y="Observed", 
          facet.by = "Method", add="reg.line", conf.int=T, cor.coef = T, 
          cor.coeff.args = list(method="spearman"),
          xlab="Observed richness (original communities)",
          ylab="Observed richness (transformed data)",
          title="Correlation of observed richness values between original and transformed data") +
    theme_bw()

ggscatter(diversity_comparison, x="Shannon_original", y="Shannon", 
          facet.by = "Method", add="reg.line", conf.int=T, cor.coef = T, 
          cor.coeff.args = list(method="spearman"),
          xlab="Shannon diversity (original communities)",
          ylab="Shannon diversity (transformed data)",
          title="Correlation of Shannon diversity values between original and transformed data") +
    theme_bw()

# How do these three methods compare? What if you change the Spearman correlation for Pearson?
# What can you conclude of these results?


## 2.5 For each normalized dataset, calculate differentially abundant taxa and compare with the original data

# list all the datasets
normalized_data_list <- list(ps_RMP, ps_CLR, ps_VST, ps_ACS, ps_QMP)
names_methods <- c("RMP", "CLR", "VST","ACS", "QMP")

# Convert the phyloseq objects to apply the Wilcoxon rank-sum test (may take ~3-4 minutes)
differential_abundances <- tibble()
for(i in 1:length(normalized_data_list)){
    # convert each individual dataset and add a column specifying the type of transformation
    dataset <- psmelt(normalized_data_list[[i]]) %>% 
        as_tibble() %>% 
        mutate(method=names_methods[i])
    # remove unnecessary columns and get full species names
    dataset <- dataset %>% 
        dplyr::select(-Kingdom, -Phylum, -Class, -Order, -Family) %>% 
        unite(Species_name, Genus, Species, sep=" ")
    # calculate differential abundance for this specific dataset as above
    differential_abundances_dataset <- dataset %>% 
        group_by(Species_name) %>% 
        wilcox_test(Abundance ~ disease_status) %>% 
        mutate(p_adjusted=p.adjust(p, method="BH")) %>% 
        mutate(Method=names_methods[i])
    # calculate also the mean value of the differences (wilcox_test calculates the median, but when prevalence is low sometimes is better to determine the mean)
    mean_differences <- dataset %>% 
        group_by(Species_name, disease_status) %>% 
        mutate(abundance=mean(Abundance)) %>% 
        dplyr::select(Species_name, abundance, disease_status) %>% 
        distinct() %>% 
        ungroup %>% 
        spread(key="disease_status", value="abundance") %>% 
        mutate(estimate=Control-Patient) %>% 
        dplyr::select(-Control, -Patient)
    # bind all results together
    differential_abundances_dataset <- differential_abundances_dataset %>% 
        left_join(mean_differences, by="Species_name")
    differential_abundances <- bind_rows(differential_abundances, differential_abundances_dataset)
}

# Now, we will calculate how many true positives, discordant taxa, false positives, true negatives and false negatives each method has

# first, we clean the results from the real dataset
diff_abundances_real_significance <- diff_abundances_real %>% 
    mutate(p_adjusted_significant=p_adjusted<0.05) %>% 
    mutate(direction_change=sign(estimate)) %>% 
    dplyr::select(Species_name, direction_change, p_adjusted_significant)

class_taxa <- c()
for(i in 1:nrow(differential_abundances)){
    taxa <- differential_abundances$Species_name[i]
    direction_change <- sign(differential_abundances$estimate[i])
    p_adjusted_significant <- differential_abundances$p_adjusted[i]<0.05
    # get results from the original dataset for this taxon
    real_values <- diff_abundances_real_significance %>% 
        dplyr::filter(Species_name==taxa)
    # evaluate the category of each taxon for each of the methods
    if(p_adjusted_significant==T & real_values$p_adjusted_significant==T & direction_change==real_values$direction_change){
        class_taxa <- c(class_taxa, "True positive")
    } else if(p_adjusted_significant==T & real_values$p_adjusted_significant==T & direction_change!=real_values$direction_change){
        class_taxa <- c(class_taxa, "Discordant")
    } else if(p_adjusted_significant==T & real_values$p_adjusted_significant==F){
        class_taxa <- c(class_taxa, "False positive")
    } else if(p_adjusted_significant==F & real_values$p_adjusted_significant==F){
        class_taxa <- c(class_taxa, "True negative")
    } else if(p_adjusted_significant==F & real_values$p_adjusted_significant==T){
        class_taxa <- c(class_taxa, "False negative")
    }
}


# make a summary to plot
summary_results <- differential_abundances %>% 
    mutate(class_taxa) %>% 
    dplyr::select(Method, class_taxa) %>% 
    table %>% 
    as_tibble()

# reorder classes and methods
summary_results$class_taxa <- factor(summary_results$class_taxa, levels=c("True positive", 
                                                                          "False positive",
                                                                          "Discordant", 
                                                                          "False negative",
                                                                          "True negative"))

summary_results$Method <- factor(summary_results$Method, levels=c("RMP", "CLR", "VST", "ACS", "QMP"))

# Plot
ggbarplot(summary_results, x="Method", y="n", fill="class_taxa",
          palette="Spectral", legend.title="Class", 
          title="Performance of the different transformations in differential abundance testing") +
    theme_bw()

# The majority of the taxa were more abundant in the healhty controls (because their microbial loads are higher)
# Normally, we are interested in finding taxa especifically associated to disease - (like the opportunists), 
# while minimizing the false positives

# here, we select the taxa that the different normalizations recover as associated to the disease
disease_associated <- differential_abundances %>% 
    mutate(class_taxa) %>% 
    dplyr::filter(p_adjusted < 0.05 & sign(estimate)==-1) %>% 
    dplyr::select(Method, class_taxa) %>% 
    table %>% 
    as_tibble()

# reorder classes and methods
disease_associated$class_taxa <- factor(disease_associated$class_taxa, levels=c("True positive", 
                                                                          "False positive",
                                                                          "Discordant", 
                                                                          "False negative",
                                                                          "True negative"))

disease_associated$Method <- factor(disease_associated$Method, levels=c("RMP", "CLR", "VST", "ACS", "QMP"))


ggbarplot(disease_associated, x="Method", y="n", fill="class_taxa",
          palette=get_palette("Spectral", 5)[1:3], legend.title="Class", 
          title="Detection of taxa associated to the disease: real or not?") +
    theme_bw()

# All of the methods manage to recover the 2 taxa that are significantly increased in the patients, 
# However the performance varies a lot in terms of false positives datection
# RMP and CLR detect a number of false positives (taxa that do not change between groups) 
# and discordant taxa (taxa that in the real dataset are more abundance in the controls, but they detect as more abundant in the disease)
# VST (DESeq2) improves a lot as it detects a lot less discordant taxa, but still has false positives.
# The experimental transformations do not detect any discordant taxa, but ACS has more false positives detected than QMP


