
# Hands-on #2: "Microbiome data visualisation, diversity, differential abundance and normalisations"

Part 1. Data normalization 

This is the repo for the second hands-on tutorial in the Microbiome Data Analyses Workshop (https://mdawo.meetinghand.com/). In this tutorial, I will demonstrate how different data normalizations impact the conclusions we can extract from a microbiome dataset, and will give guidelines on which normalizations to choose. 

To do so, we will work with a simulated gut microbiome dataset, representing a case-control scenario, with ~half of the samples from patients with a given disorder and the rest being healthy controls. 
Besides testing the normalizations, in this tutorial we will be using the phyloseq package and thus we will demonstrate some of its functions to plot and manipulate microbiome data.

Here, you will find:

- `hands_on_2_data_normalization.Rproj`: the R project from within we will follow the tutorial
- `hands_on_2_data_normalization.Rmd`: the tutorial as a R markdown notebook that can be compiled into an html file
- `hands_on_2_data_normalization.html`: the compiled version of this tutorial: it can be visualized either downloading the files or by clicking [here](https://htmlpreview.github.io/?https://github.com/vllorens/MDAW_hands_on_2_data_normalization/blob/main/hands_on_2_data_normalization.html)
- a `data/` folder: here, you have the original simulated dataset as well as well as the simulated sequencing 
- an `output/` folder: to host the output files from the tutorial
- a `scripts/` folder: contains a script version of the Rmd file and the source code of functions used in the tutorial
- this `README.md` file