library('methods')
library('foreach')
library('doMC')
#registerDoMC()
library('IRanges')

##-------------------------------------------------
## Set up an object to hold the data,
##
initRdClass <- function(){
  setClass("rdObject", representation(params="data.frame", binParams="data.frame", entrypoints="data.frame", readInfo="data.frame", chrs="list"))
  setMethod("initialize", "rdObject",
          function(.Object){
            .Object@params=data.frame()
            .Object@binParams=data.frame()
            .Object@entrypoints=data.frame()
            .Object@readInfo=data.frame()
            .Object@chrs=as.list(c())
            return(.Object)              
          })
}

##-------------------------------------------------
## Fill the rd object with the appropriate parameters
##
setParams <- function(rdo, annotationDirectory, outputDirectory, inputFile, inputType,
                      maxCores=0, #0 means use all available cores
                      binSize=0,  #0 means let copyCat choose (or infer from bins file)
                      gcWindowSize=100, fdr=0.01, perLibrary=TRUE, perReadLength=TRUE, readLength=0, verbose=FALSE){
  #sanity checking
  if(!(inputType=="bam" | inputType=="bins")){
    print("inputType parameter must be either \"bam\" or \"bins\"")
    stop()
  }
  if(!(file.exists(inputFile))){
    print(paste("file \"",inputFile,"\" does not exist"))
    stop()
  }  
  ## if(binSize==0){
  ##   if(inputType=="bins"){
  ##     print("If a bin file is provided, the binSize must be specified (and match the contents of the bin file)")
  ##     stop()
  ##   }
  ## }

  verbose <<- verbose;
  
  #fill the params data frame
  rdo@params <- data.frame(annotationDirectory=annotationDirectory,
                           outputDirectory=outputDirectory,
                           inputFile=inputFile,
                           inputType=inputType,
                           maxCores=maxCores,
                           binSize=binSize,
                           gcWindowSize=gcWindowSize,
                           fdr=fdr,
                           perLibrary=perLibrary,
                           perReadLength=perReadLength,
                           readLength=readLength
                           )

  if(inputType == "bins"){
    rdo@params$binFile=inputFile
  }
  
  ##fill entrypoints
  rdo@entrypoints=readEntrypoints(rdo@params$annotationDirectory)
  ## TODO - maybe only do this if we're estimating window size
  #rdo@entrypoints=addMapability(rdo@entrypoints,annotationDirectory)
  
  ##set multicore options if specified
  if(maxCores > 0){
    options(cores = maxCores)
  }

  #make sure the output directory exists, if not, create it
  if(!(file.exists(outputDirectory))){
    dir.create(outputDirectory)
  }
  #also create a subdirectory for plots
  if(!(file.exists(paste(outputDirectory,"/plots",sep="")))){
    dir.create(paste(outputDirectory,"/plots",sep=""))
  }
  
  return(rdo)  
}



## ##-------------------------------------------------
## ## calculate the appropriate bin size,
## ## gain/loss thresholds, number of chromosomes, etc
## ##

## calculateBinSize <-function(rdo, overdispersion=3, percCnGain=0.05, percCnLoss=0.05){
##   params = rdo@params
##   entrypoints = rdo@entrypoints
  
##   if(params$inputType != "bam"){
##     stop("optimal window size can only be calculated from bam input")
##   }
   
##   numReads = getNumReads(params$inputFile,params$outputDirectory)
  
##   ## get genome size from entrypoints file, adjust by mappability estimates
##   genomeSize = sum(entrypoints$length)
##   mapPerc=sum(entrypoints$mapPerc*entrypoints$length)/sum(entrypoints$length)
##   effectiveGenomeSize = genomeSize * mapPerc

##   if(verbose){
##     cat(numReads," total reads\n")
##     cat("genome size:",genomeSize,"\n")
##     cat("genome mapability percentage:",mapPerc,"\n")
##     cat("effectiveGenomeSize:",effectiveGenomeSize,"\n")
##   }


##   ## median value has to be adjusted if we have chromosomes with single ploidy
##   ## or expected copy number alterations
##   ploidyPerc = ploidyPercentages(effectiveGenomeSize,entrypoints,params)

##   if(verbose){
##     cat("expect ",
##         ploidyPerc$haploidPerc*100,"% haploid,",
##         ploidyPerc$diploidPerc*100,"% diploid,",
##         ploidyPerc$triploidPerc*100,"triploid\n")
##   }

##   ## est. coverage of genome by reads
##   coverage = numReads * params$readLength / effectiveGenomeSize
##   if(verbose){
##     cat("approx.",coverage," X coverage of mappable genome \n")
##   }

##   ## calculate window size based on triploid peak, since it always
##   ## produces larger (more conservative) windows
##   ploidy = 3
##   medAdj = 1
##   if(verbose){
##     if("medAdjustment" %in% names(params)){
##       medAdj = params$medAdjustment
##     }
##   }

##   pTrip <- calcWindParams(numReads=numReads,
##                           fdr=params$fdr,
##                           genomeSize=effectiveGenomeSize,
##                           oDisp=params$overDispersion,
##                           ploidy=ploidy,
##                           minSize=params$gcWindowSize,
##                           ploidyPerc=ploidyPerc,
##                           medAdj=medAdj)


##   binSize = pTrip$binSize
##   binSize = round(binSize/100)*100
##   med=pTrip$med
##   if(verbose){
##     cat("expected mean: ",numReads/(effectiveGenomeSize/binSize),"\n")
##     cat("adjusted mean: ",med,"\n")
##   }

##   ## calculate separation peak for haploid peak
##   pHap = fdrRate(binSize, 1, effectiveGenomeSize, numReads, params$overDispersion, ploidyPerc, medAdj)

## ##   ##plot the output for later review
## ##   pdf("output/cnSeparation.pdf")
## ##   plotWindows(pTrip$binSize, effectiveGenomeSize, pHap$div, pTrip$div, params$fdr, numReads, params$overDispersion, ploidyPerc, med)
## ##   dev.off()

##   rdo@binParams=data.frame(binSize=binSize, lossThresh=pHap$div, gainThresh=pTrip$div, med=med, hapPerc=ploidyPerc$haploidPerc, dipPerc=ploidyPerc$diploidPerc, tripPerc=ploidyPerc$triploidPerc)

##   return(rdo)
## }


## ##--------------------------------------------------
## ## calculate adjusted genome size, based on the fact that we
## ## may have haploid chromosomes and/or expected CN alterations
## ploidyPercentages <- function(effectiveGenomeSize,ents,params){
##   ##first, get the coverage that come from diploid chrs
##   diploidPerc = sum((ents$length*ents$mapPerc)[which(ents$ploidy==2)])/effectiveGenomeSize
##   diploidPerc = diploidPerc - params$percCNLoss
##   diploidPerc = diploidPerc - params$percCNGain

##   ##coverage from haploid chrs
##   haploidPerc = sum((ents$length*ents$mapPerc)[which(ents$ploidy==1)])/effectiveGenomeSize
##   haploidPerc = haploidPerc + params$percCNLoss

##   return(data.frame(haploidPerc=haploidPerc,
##                     diploidPerc=diploidPerc,
##                     triploidPerc=params$percCNGain))
## }


##--------------------------------------------------
## returns the percentage of genome covered by
## mappable sequence
##
## if a coverage total file exists, use its value
## else, sum the lengths of the annotations, and
## create the cov total file
##
addMapability <-function(entrypoints, annoDir, readLength=100){
  ##first, we need the mappable regions
  annodir = getAnnoDir(annoDir, readLength)
  mapTotalFileName = paste(annodir,"/mapability/totalMappablePerc",sep="")
  mapDir = paste(annoDir,"/readlength.",readLength,"/mapability/",sep="")
  mapTots = 0
  #default is 100% mapability
  entrypoints = cbind(entrypoints,mapPerc=rep(1,length(entrypoints$chr)))
  tmp=NULL
  #file doesn't exist - create it
  if(!(file.exists(mapTotalFileName))){
    sumMaps <- function(filename){
      a=scan(gzfile(filename),what=0,quiet=TRUE)
      return(sum(a)/length(a))
    }
    e=NULL;
    tmp=foreach(e=entrypoints$chr, .combine="append") %do%{
      c(e,sumMaps(paste(mapDir,e,".dat.gz",sep="")))
    }
    ##now, place map perc in the appropriate part of the table
    for(i in seq(1,length(tmp),2)){
      entrypoints[which(entrypoints$chr==tmp[i]),]$mapPerc = tmp[i+1]
    }
    write.table(entrypoints[,c("chr","mapPerc")],file=mapTotalFileName,sep="\t",quote=F,row.names=F,col.names=F)
    closeAllConnections()
  }

  tmp = scan(mapTotalFileName,what="",quiet=TRUE)
  for(i in seq(1,length(tmp),2)){
    mapp=as.numeric(tmp[i+1])
    if(tmp[i] %in% entrypoints$chr){
      entrypoints[which(entrypoints$chr==tmp[i]),]$mapPerc = mapp
    }
  }

  closeAllConnections()
  entrypoints$mapPerc= as.numeric(entrypoints$mapPerc)
  return(entrypoints)
}
